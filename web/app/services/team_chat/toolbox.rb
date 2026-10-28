# frozen_string_literal: true

require 'json'
require 'securerandom'

module TeamChat
  # Everything @rupert can do in a room, built for the person who asked:
  #
  # - Ask Rupert's lookups (where_is, how_do_i, search, system_status).
  # - Every read-only MCP tool that person's permissions allow (sales, stock,
  #   tasks, alerts, time, system health...): the same tools external agents use.
  # - Write tools (create_task, submit_feedback) only as *proposals*: the model's
  #   call is saved on the reply as an action card, and nothing happens until a
  #   person allowed to do it presses Approve (TeamChat::Actions).
  #
  # Results are data for the model, never instructions; personal contact details
  # are removed before the model sees them. Each call is logged by name and outcome.
  class Toolbox
    MAX_RESULT_CHARS = 6_000
    MAX_CALLS = 8
    LOOKUPS = %w[where_is how_do_i search system_status].freeze
    WRITE_TOOLS = %w[create_task update_task submit_feedback].freeze
    EXCLUSION_CLAUSE = /\b(?:without|do not|don't|never|no(?=\s+(?:new\s+)?(?:tasks?|feedback)\b))(?:(?![.!?;,]|\b(?:but|however|instead|while|then)\b).){0,160}/i
    EXCLUDED_WRITES = {
      'create_task' => /\b(?:creat(?:e|ing)|mak(?:e|ing)|add(?:ing)?|open(?:ing)?)\b.{0,35}\btasks?\b|\b(?:no|without)\s+(?:(?:a|any|new)\s+)*tasks?\b/i,
      'update_task' => /\b(?:updat(?:e|ing)|chang(?:e|ing)|modif(?:y|ying))\b.{0,35}\btasks?\b|\b(?:no|without)\s+(?:(?:a|any|new)\s+)*tasks?\b/i,
      'submit_feedback' => /\b(?:send(?:ing)?|submit(?:ting)?|fil(?:e|ing)|creat(?:e|ing))\b.{0,35}\bfeedback\b|\b(?:no|without)\s+(?:(?:a|any)\s+)*feedback\b/i
    }.freeze

    Definition = Struct.new(:name, :description, :schema, :kind, :activity, keyword_init: true)

    attr_reader :calls, :tools_used, :results, :financial_evidence, :inventory_results, :alert_results, :views
    attr_accessor :call_id, :execution_info

    # only: tool names to offer (the question's data guide topics, for local bots); nil offers every tool.
    def initialize(user:, room:, reply:, only: nil, execution: nil, question: nil)
      @only = only&.map(&:to_s)
      @user = user
      @room = room
      @reply = reply
      @token = Token.new(user)
      @lookups = AskRupert::Tools.new(user: user)
      @execution = execution
      @question = question.to_s
      saved = execution&.run&.tool_results || []
      @views = []
      @calls = saved.size
      @tools_used = saved.pluck('name')
      @results = saved.pluck('result')
      @inventory_results = saved.filter_map { |entry| entry['result'] if entry['name'] == 'inventory_search' }
      @alert_results = saved.filter_map { |entry| entry['result'] if entry['name'] == 'list_alerts' }
      @financial_evidence = saved.filter_map { |entry| FinancialEvidence.decode(entry['result'], @user.tenant_id, tool: entry['name'], invocation: entry['id']) if FinancialEvidence::CONTRACTS.include?(entry['name']) }
      @financial = saved.any? { |entry| FinancialEvidence::TOOLS.include?(entry['name']) || FinancialEvidence.decode(entry['result'], @user.tenant_id).present? }
    end

    def definitions
      @definitions ||= begin
        available = lookup_definitions + mcp_definitions + write_definitions + view_definitions
        narrow = if QueueEvidence.count_question?(@question)
          'order_queues'
        elsif ComplianceEvidence.narrow_title(@question)
          'compliance_check'
        end
        if @only && narrow && available.any? { |tool| tool.name == narrow }
          available.select { |tool| [narrow, 'show_view'].include?(tool.name) }
        else
          available
        end
      end
    end

    def financial? = @financial

    def names = definitions.map(&:name)

    def activity_for(name)
      definitions.find { |definition| definition.name == name.to_s }&.activity || 'Working'
    end

    # RubyLLM tool objects for native tool calling.
    def llm_tools
      definitions.map { |definition| LlmTool.build(definition) { |args| call(definition.name, args) } }
    end

    # The tool list as text, for the opencode CLI engine (no native tool calling).
    def prompt_section
      definitions.map do |definition|
        props = definition.schema[:properties] || {}
        required = Array(definition.schema[:required]).map(&:to_s)
        args = props.map { |key, spec| "#{key}#{'*' if required.include?(key.to_s)}#{" (#{spec[:enum].join('|')})" if spec[:enum]}" }.join(', ')
        "- #{definition.name}(#{args}) — #{definition.description.to_s.first(220)}"
      end.join("\n")
    end

    # Runs one call and returns text for the model. Never raises.
    def call(name, arguments)
      original_arguments = arguments.is_a?(Hash) ? arguments.deep_stringify_keys : {}
      arguments = original_arguments
      arguments = complete_daily_arguments(name, arguments)
      arguments = complete_tax_source_arguments(name, arguments)
      arguments = complete_order_day_comparison(name, arguments)
      arguments = complete_order_count_comparison(name, arguments)
      arguments = complete_sales_by_source(name, arguments)
      arguments = correct_sales_day_direction(name, arguments)
      arguments = complete_focused_compliance_arguments(name, arguments)
      arguments = complete_vendor_payment_arguments(name, arguments)
      arguments = complete_exact_vendor_filter(name, arguments)
      return call_once(name, arguments) unless @execution

      @execution.tool!(call_id, name, arguments || {}, write: WRITE_TOOLS.include?(name), original_arguments: original_arguments) do
        TelemetryRecorder.new(@execution.run, @execution.token).measure('tool',
          facts: { 'name' => names.include?(name.to_s) ? name.to_s : 'unknown' }) do |span|
          @telemetry_span = span
          begin
            call_once(name, arguments)
          ensure
            @telemetry_span = nil
          end
        end
      end
    end

    def call_once(name, arguments)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @calls += 1
      return log(name, started, 'budget_exhausted', 'Tool budget used up for this message. Answer now from what you already have, and say what you could not check.') if @calls > MAX_CALLS

      definition = definitions.find { |candidate| candidate.name == name.to_s }
      return log(name, started, 'unknown', "No tool named #{name.to_s.first(40)}. Use one of: #{names.join(', ')}.") unless definition

      args = arguments.is_a?(Hash) ? arguments.deep_stringify_keys.compact : {}
      coerced, problems = Mcp::SchemaValidator.call(definition.schema, args)
      return log(name, started, 'invalid', "Invalid arguments: #{problems.first(3).join(' ')}") if problems.any?

      @financial = true if FinancialEvidence::TOOLS.include?(definition.name)
      @tools_used << definition.name
      if definition.kind == :write && excluded_write?(definition.name)
        return log(name, started, 'denied', 'The person explicitly excluded this action; do not propose it.')
      end
      text = case definition.kind
             when :lookup then run_lookup(definition.name, coerced)
             when :mcp then run_mcp(definition.name, coerced)
             when :write then propose(definition.name, coerced)
             when :view then show_view(coerced)
             end
      log(name, started, 'ok', text)
    rescue Mcp::ToolError => e
      log(name, started, 'error', e.message.to_s.first(400))
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { team_chat_tool: name.to_s.first(40) })
      log(name, started, 'error', 'That lookup failed. Say you could not check it and suggest the page itself.')
    end

    private

    def excluded_write?(name)
      pattern = EXCLUDED_WRITES[name]
      # Quoted titles and descriptions are data, not exclusions of the action
      # the person requested. Preserve apostrophes inside words such as don't.
      question = @question.gsub(/"[^"]*"|“[^”]*”|‘[^’]*’|(?<!\w)'[^']*'(?!\w)/, ' ')
      pattern && question.scan(EXCLUSION_CLAUSE).any? { |clause| clause.match?(pattern) }
    end

    # A daily sales request needs the series flag; small models often omit it
    # even when they select the right tool and dates. Keep explicit arguments.
    def complete_daily_arguments(name, arguments)
      return arguments unless name.to_s == 'sales_summary' && arguments.is_a?(Hash)
      return arguments unless @question.match?(/\b(?:daily\s+(?:sales|orders|revenue|breakdown|series)|day[- ]by[- ]day|each day|per day)\b/i)
      return arguments if @question.match?(/\b(?:no|without|omit|exclude|skip)\s+(?:(?:a|the|any)\s+)?(?:daily|day[- ]by[- ]day|per[- ]day)\b/i)

      args = arguments.deep_stringify_keys
      args['include_daily'] = true unless args.key?('include_daily')
      args
    end

    # Metric defaults to a previous-period comparison. A standalone order-count
    # question asks for the count only; keep any comparison the caller supplied.
    def complete_order_count_comparison(name, arguments)
      return arguments unless name.to_s == 'metric' && arguments['name'] == 'orders' && !arguments.key?('compare')

      question = @question.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip
      return arguments unless question.match?(/\Ahow many (?:paid |fulfilled )?orders (?:were recorded|came in|were placed|did we get) (?:today|yesterday)\s*[?.!]*\z/i)

      arguments.merge('compare' => 'none')
    end

    # A request for the total and its source breakdown cannot be answered by
    # an aggregate-only metric. Preserve explicit filters and comparisons.
    def complete_sales_by_source(name, arguments)
      return arguments unless name.to_s == 'metric' && arguments['name'] == 'gross_sales' && arguments['source'].blank?
      return arguments if arguments['from'].present? || arguments['to'].present?

      question = @question.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip
      match = question.match(/\Awhat (?:were|was) (?:our )?total gross sales (today|yesterday|this month|last month),? by source\s*[?.!]*\z/i)
      return arguments unless match && arguments['period'].to_s == match[1].downcase.tr(' ', '_')

      corrected = arguments.merge('name' => 'sales_by_source')
      corrected['compare'] = 'none' unless corrected.key?('compare')
      corrected
    end

    # The best and slowest recorded sales days are different metrics. Correct
    # only an unambiguous single-subject question and preserve every filter.
    def correct_sales_day_direction(name, arguments)
      return arguments unless name.to_s == 'metric' && %w[best_day worst_day].include?(arguments['name'])

      question = @question.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip
      return arguments if question.match?(/["“”‘’]/) || question.match?(/\b(?:and|also|plus|versus|vs|compare|weekday|weekdays)\b|\bday of (?:the )?week\b/i)
      return arguments unless question.match?(/\b(?:sales|selling)\b/i) && question.match?(/\bday\b/i)

      worst = question.match?(/\b(?:slowest|worst|lowest)\b/i)
      best = question.match?(/\b(?:best|busiest|strongest|highest)\b/i)
      return arguments if worst == best

      arguments.merge('name' => worst ? 'worst_day' : 'best_day')
    end

    def complete_focused_compliance_arguments(name, arguments)
      return arguments unless name.to_s == 'compliance_check' && ComplianceEvidence.focused_title(@question)

      arguments.merge('include_ok' => true)
    end

    # A missing filter can otherwise turn a source-specific tax question into
    # an unrelated aggregate. Do not infer one for comparisons or exclusions.
    def complete_tax_source_arguments(name, arguments)
      return arguments unless name.to_s == 'metric' && arguments['name'] == 'tax_collected' && arguments['source'].blank?
      return arguments if @question.match?(/["“”‘’]/) || @question.match?(/\b(?:all|both|every|compare|comparison|versus|vs|except|excluding|exclude|without|not)\b/i)

      sources = @question.scan(/\b(?:shopify|square|rupert[ _]pos|manual|ctrax|swipesimple)\b/i).map(&:downcase).uniq
      match = @question.match(/\b(?:on|from|for)\s+(?:the\s+)?(shopify|square)\s+(?:orders|sales)\b/i)
      return arguments unless match && sources == [match[1].downcase]

      arguments.merge('source' => match[1].downcase)
    end

    # A single-day order count against the same day last year has one clear
    # metric and comparison window. Keep original arguments for replay.
    def complete_order_day_comparison(name, arguments)
      return arguments unless name.to_s == 'metric' && %w[orders gross_sales].include?(arguments['name'])

      question = @question.sub(/\A\s*(?:@[\w.-]+\s+)+/, '').strip
      match = question.match(/\A(?:(?:how many|number of|count of)\s+)?orders\s+(today|yesterday)\s+(?:vs\.?|versus|compared\s+(?:to|with))\s+(?:the\s+)?same\s+(?:day|date)\s+last year[?.!]*\z/i)
      return arguments unless match

      arguments.except('from', 'to').merge('name' => 'orders', 'period' => match[1].downcase, 'compare' => 'last_year')
    end

    # A named vendor value/payment question needs the vendor view, not an
    # order/sku query. Only correct a unique exact tenant match and preserve
    # requests that ask for individual order or line details.
    def complete_vendor_payment_arguments(name, arguments)
      return arguments unless name.to_s == 'purchase_orders' && arguments.is_a?(Hash)
      return arguments unless @question.match?(/\b(?:vendor|supplier)\s+payments?\b/i) && names.include?('purchase_orders')
      return arguments unless @question.match?(/\b(?:value|total|spend|how much|what were)\b/i)
      return arguments if @question.match?(/\b(?:line items?|line-item|sku|individual|which orders|order numbers?|status|open orders)\b/i)
      return arguments if @question.match?(/\b(?:starts? with|contains?|matching|similar|prefix)\b/i)

      args = arguments.deep_stringify_keys
      return arguments if args.key?('vendor_exact') || (args['vendor'].present? && args['query'].present?)
      return arguments unless [nil, '', 'orders', 'vendors'].include?(args['view'])
      return arguments if args.key?('status') && args['status'] != 'all'
      query = (args['vendor'].presence || args['query']).to_s.strip
      return arguments if (args.keys - %w[view vendor query from to status]).any?
      if query.blank?
        match = @question.match(/\bfor\s+(.{1,80}?)\s+(?:this month|last month|today|yesterday)\b/i)
        query = match && match[1].strip
      end
      return arguments if query.blank?
      return arguments unless unique_vendor_mentioned?(query)

      args['view'] = 'vendors'
      args.delete('query')
      args.delete('status')
      args['vendor'] = query
      args['vendor_exact'] = true
      periods = { 'this month' => 'this_month', 'last month' => 'last_month', 'today' => 'today', 'yesterday' => 'yesterday' }
        .filter_map { |words, key| key if @question.match?(/\b#{words}\b/i) }
      if periods.one? && !@question.match?(/\b(?:versus|vs|compare|compared|previous)\b/i) && !args.key?('from') && !args.key?('to')
        preset = TimeRangePicker.preset(periods.first, Date.current)
        args['from'] = preset.from.iso8601
        args['to'] = [preset.to, Date.current].min.iso8601
      end
      args
    end

    # Preserve the model's requested view and filters, while avoiding a
    # substring vendor match when the person named one unambiguous vendor.
    def complete_exact_vendor_filter(name, arguments)
      return arguments unless name.to_s == 'purchase_orders' && arguments.is_a?(Hash)
      return arguments unless @question.match?(/\b(?:vendor|supplier)\s+payments?\b/i) && names.include?('purchase_orders')
      return arguments if @question.match?(/\b(?:starts? with|contains?|matching|similar|prefix)\b/i)

      args = arguments.deep_stringify_keys
      vendor = args['vendor'].to_s.strip
      return arguments if args.key?('vendor_exact') || vendor.blank? || !unique_vendor_mentioned?(vendor)

      args['vendor_exact'] = true
      args
    end

    def unique_vendor_mentioned?(name)
      vendor_reference = /\bfor\s+#{Regexp.escape(name)}(?=\s+(?:this month|last month|today|yesterday)\b|[,;?.])/i
      return false unless @question.match?(vendor_reference)

      Purchasing::Vendor.where(tenant_id: @user.tenant_id).where('LOWER(name) = ?', name.downcase).limit(2).count == 1
    end

    def lookup_definitions
      @lookups.definitions.select { |definition| LOOKUPS.include?(definition.name) }.map do |definition|
        Definition.new(name: definition.name, description: definition.description, kind: :lookup,
          schema: { type: 'object', properties: definition.properties, required: definition.required, additionalProperties: false },
          activity: { 'where_is' => 'Finding the page', 'how_do_i' => 'Looking up how it works', 'search' => 'Searching records',
                      'system_status' => 'Checking system status' }[definition.name])
      end
    end

    def mcp_definitions
      Mcp::Registry.available_to(@token).select(&:read_only).select { |tool| offered?(tool.tool_name) }.map do |tool|
        Definition.new(name: tool.tool_name, description: tool.description, kind: :mcp, schema: tool.input_schema,
          activity: "Checking #{tool.title.to_s.downcase.presence || tool.tool_name.tr('_', ' ')}")
      end
    end

    # show_view is offered to every bot: it only displays data the bot already has.
    def view_definitions
      [Definition.new(name: 'show_view', description: Views::DESCRIPTION, kind: :view, schema: Views::SCHEMA, activity: 'Building a view')]
    end

    def show_view(args)
      return 'You already showed the most views allowed for one reply; answer now.' if @views.size >= Views::MAX_VIEWS

      view = Views.build(args, known_text: @results.join("\n"))
      @views << view
      flagged = view['unchecked'].to_i.positive? ? " #{view['unchecked']} of its figures are not in your tool results and will be flagged; fix them if you can." : ''
      "Shown beside the chat as “#{view['title']}” (a button under your reply opens it).#{flagged} Say in your reply what it shows."
    rescue ArgumentError => e
      "The view was not shown: #{e.message}."
    end

    def write_definitions
      WRITE_TOOLS.select { |name| offered?(name) }.filter_map { |name| Mcp::Registry.find(name) }.select { |tool| Actions.permitted?(@user, tool) }.map do |tool|
        Definition.new(name: tool.tool_name, kind: :write, schema: tool.input_schema, activity: 'Preparing a change for approval',
          description: "PROPOSES a change; nothing happens until a person presses Approve on the card it creates. #{tool.description}")
      end
    end

    def offered?(name) = @only.nil? || @only.include?(name.to_s)

    def run_lookup(name, args)
      result = @lookups.call(name, args)
      result.text.to_s
    end

    def run_mcp(name, args)
      tool = Mcp::Registry.find(name)
      outcome = tool.new(token: @token).call(args)
      if name == 'compliance_check'
        title = ComplianceEvidence.focused_title(@question)
        packed = ComplianceEvidence.pack(outcome.data, requested_title: title)
        return "Compliance check (bounded; omitted items are indicated):\n#{JSON.generate(packed)}"
      end
      if FinancialEvidence::CONTRACTS.include?(name) || FinancialEvidence.financial_data?(outcome.data)
        @financial = true
        evidence = FinancialEvidence.build(tool: name, data: outcome.data, arguments: args, tenant_id: @user.tenant_id, invocation: call_id || "call-#{@calls}")
        @financial_evidence << evidence
        return JSON.generate(evidence)
      end
      if name == 'list_alerts'
        return "Low-stock alerts are not a complete inventory check; no matching alerts do not prove stock is sufficient.\n" \
          "#{JSON.generate(AlertEvidence.pack(outcome.data, args: args))}"
      end
      AskRupert::Redactor.personal("#{outcome.text}\n#{JSON.generate(with_dollars(outcome.data))}")
    end

    # Adds a ready-made "$214.83" beside every *_cents amount, so models quote dollars instead of converting cents.
    def with_dollars(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, inner), out|
          out[key] = with_dollars(inner)
          name = key.to_s
          out["#{name.delete_suffix('_cents')}_dollars"] = dollars(inner) if name.end_with?('_cents') && inner.is_a?(Numeric)
        end
      when Array then value.map { |inner| with_dollars(inner) }
      else value
      end
    end

    def dollars(cents)
      Money.format(cents, minus: '-')
    end

    def propose(name, args)
      args = prepare(name, args)
      action = Actions.propose!(@reply, tool: name, arguments: args, proposed_for: @user, execution_info: execution_info || {})
      "Proposed as action #{action['id']}: “#{action['summary']}”. A card with Approve and Dismiss is shown in the room. " \
        'Tell them it is waiting for their approval. Do not say it is done.'
    end

    # Checks what can be checked before a card is shown, so the model can ask
    # again (which person? which task?) instead of the change failing at Approve.
    # The person is pinned by email so Approve assigns exactly who the card names.
    def prepare(name, args)
      args = args.dup
      if args['assignee'].present? && %w[create_task update_task].include?(name)
        person = Mcp::Assignee.resolve(@user, args['assignee'])
        args['assignee'] = person == :nobody ? 'nobody' : person.email
      end
      if name == 'update_task'
        task = Projects::TaskPolicy::Scope.new(@user, Projects::Task).resolve.find_by(id: args['task_id'])
        raise Mcp::ToolError.new("No task ##{args['task_id']} that this person can see. Use list_tasks to find it.", kind: 'not_found') unless task
        raise Mcp::ToolError.new("This person cannot change task ##{task.id}.", kind: 'denied') unless Projects::TaskPolicy.new(@user, task).update?

        args['task_title'] = task.title
      end
      args
    end

    def log(name, started, outcome, text)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      @telemetry_span&.update!(facts: @telemetry_span.facts.merge('result_outcome' => outcome))
      ActivityLogger.log('team_chat_tool', actor: @user,
        details: "tool=#{name.to_s.gsub(/[^\w]/, '?').first(30)}; outcome=#{outcome}; duration_ms=#{ms}; room=#{@room.id}")
      text = text.to_s.first(MAX_RESULT_CHARS)
      @results << text
      @inventory_results << text if name.to_s == 'inventory_search' && outcome == 'ok'
      @alert_results << text if name.to_s == 'list_alerts'
      text
    end
  end
end
