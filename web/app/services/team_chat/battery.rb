# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'timeout'

module TeamChat
  # A fixed set of questions (config/team_chat/battery.yml) asked to one bot in
  # the bot's own test room (#test-liquid, #test-qwen, ...), one at a time, timed. Each answer is then graded by
  # DeepSeek (Battery::Grader) against the data Rupert's own tools return for the
  # same question, and the grade is posted under it. Everyone in the room can
  # watch a run; the summary is posted and pinned at the end.
  #
  # Questions only read data. A bot that proposes a change anyway gets its card
  # dismissed, so a test run never changes anything.
  class Battery
    # Each bot has its own test room (#test-liquid, #test-qwen, ...). Runs from before that are in #liquid-testing.
    LEGACY_ROOM_SLUG = 'liquid-testing'
    ROOM_TOPIC = 'Test runs for @%<handle>s: answers are timed and may be graded or retained for independent review. Scorecard: Model scores → Test runs.'
    CONFIG = Rails.root.join('config/team_chat/battery.yml')
    QUESTION_TIMEOUT = 120
    class QuestionTimeout < Exception; end

    Item = Struct.new(:id, :cadence, :question, :checks, :expect, :module, :needs, keyword_init: true)
    Result = Struct.new(:item, :seconds, :tools, :status, :answer, :grade, :grading_error, :tokens_in, :tokens_out, :unverified, :message_id, :load_seconds, :views,
      :verify, :proposed_tools, keyword_init: true)

    attr_reader :run_id, :room, :results, :record

    # The question set: the default battery, or config/team_chat/battery_<name>.yml (e.g. finance).
    def self.config_for(name)
      name = name.to_s.strip
      return CONFIG if name.blank? || name == 'default'
      raise ArgumentError, "Battery names are lowercase letters, digits and _: #{name.first(40)}" unless name.match?(/\A[a-z0-9_]+\z/)

      path = Rails.root.join("config/team_chat/battery_#{name}.yml")
      raise ArgumentError, "No battery called #{name} (#{path.basename} is missing)." unless path.exist?

      path
    end

    # Every question set: default plus each config/team_chat/battery_<name>.yml.
    def self.sets
      ['default'] + Dir[Rails.root.join('config/team_chat/battery_*.yml')].map { |path| File.basename(path, '.yml').delete_prefix('battery_') }.sort
    end

    def self.set_name_for(path)
      name = File.basename(path.to_s, '.yml')
      name == 'battery' ? 'default' : name.delete_prefix('battery_')
    end

    # Keep the fully checked battery and the broad question bank distinct so
    # their different evidence coverage never gets presented as one score.
    def self.items_for(set, per: 5)
      case set.to_s
      when 'depth'
        combined = %w[default finance cross visualization].flat_map { |name| items(config_for(name)) }
        raise ArgumentError, 'Depth question IDs must be unique across sets.' unless combined.map(&:id).uniq.size == combined.size

        combined
      when 'breadth'
        QuestionBank.questions.map { |question| QuestionBank.battery_item(question) }
      when 'bank'
        QuestionBank.battery_items(per: per)
      else
        items(config_for(set))
      end
    end

    # The set as shipped in the YAML file.
    def self.builtin_items(path = CONFIG)
      YAML.safe_load_file(path).fetch('questions').map do |row|
        Item.new(id: row.fetch('id'), cadence: row.fetch('cadence'), question: row.fetch('question'), checks: Array(row['checks']),
          expect: row['expect'].to_s.squish.presence, module: row['module'].presence, needs: Array(row['needs']).map(&:to_s))
      end
    end

    # The set as this workspace asks it: built-in questions, with its own edits (same id) and removals applied, then
    # its own new questions (TeamChat::BatteryQuestion).
    def self.items(path = CONFIG)
      base = builtin_items(path)
      edits = edits_for(set_name_for(path))
      return base if edits.empty?

      by_id = edits.index_by(&:question_id)
      kept = base.filter_map do |item|
        edit = by_id.delete(item.id)
        next item unless edit

        edit.to_item if edit.active?
      end
      kept + by_id.values.select(&:active?).sort_by(&:created_at).map(&:to_item)
    end

    def self.edits_for(set)
      return [] unless Current.tenant_id

      BatteryQuestion.where(set_name: set.to_s).order(:id).to_a
    end

    # The name a run is saved under: an edited set gets its own name (finance-edited-1a2b3c), so its scores are never
    # compared with runs of the built-in questions or of an earlier version of the edits.
    def self.run_set_name(set)
      if set.to_s == 'depth'
        children = %w[default finance cross visualization].map { |name| run_set_name(name) }
        return 'depth' if children == %w[default finance cross visualization]

        return "depth-edited-#{Digest::SHA256.hexdigest(children.to_json).first(6)}"
      end

      edits = edits_for(set)
      return set.to_s if edits.empty?

      digest = Digest::SHA256.hexdigest(edits.map { |edit| [edit.question_id, edit.status, edit.question, edit.expect, edit.checks, edit.needs] }.to_json)
      "#{set}-edited-#{digest.first(6)}"
    end

    # user: who the questions are asked as (their permissions). agent: a local bot handle, or 'rupert'.
    attr_reader :set

    def initialize(user:, agent: 'qwen', only: nil, grader: Grader.new, items: self.class.items, out: $stdout, set: 'default', cohort: nil)
      @set = set.to_s.presence || 'default'
      @run_set = self.class.run_set_name(@set)
      @run_set = "#{@run_set}-offline" if grader.is_a?(OfflineGrader)
      @user = user
      raise ArgumentError, 'cohort belongs to another requester or workspace' if cohort && !cohort.for_user?(user)
      @cohort = cohort
      @agent = agent.to_s == 'rupert' ? nil : (LocalAgents.find(agent) || LocalAgents.trial(agent))
      raise ArgumentError, "No bot @#{agent} is available here." if agent.to_s != 'rupert' && !@agent

      wanted = Array(only).map(&:to_s).compact_blank
      @items = wanted.any? ? items.select { |item| wanted.include?(item.id) } : items
      @partial = wanted.any?
      @grader = grader
      @out = out
      @run_id = "#{Time.current.strftime('%Y%m%d-%H%M')}-#{SecureRandom.hex(2)}"
      @results = []
    end

    def handle = @agent&.handle || 'rupert'
    def bot_name = @agent&.name || 'Rupert'

    def self.room_slug(handle) = "test-#{handle.presence || 'rupert'}"

    # Evaluation can read business data too: use a separate requester-owned room.
    def self.room_for(user, handle = 'qwen')
      slug = "#{room_slug(handle)}-#{user.id}"
      room = Room.find_by(slug: slug) ||
             Room.create!(name: slug, slug: slug, kind: 'direct', topic: format(ROOM_TOPIC, handle: handle.presence || 'rupert'),
               assistant_mode: 'off', created_by: user)
      raise ArgumentError, 'Test room must be private to its requester' unless room.direct? && room.created_by_id == user.id

      room.membership_for(user)
      room
    end

    # A test room for @rupert, every @bot and every trial model, so people can open them before any run.
    def self.ensure_rooms!(user)
      (['rupert'] + LocalAgents.all.map(&:handle) + (LocalAgents.enabled? ? LocalAgents::TRIALS.map(&:handle) : [])).map { |handle| room_for(user, handle) }
    end

    def run
      @room = self.class.room_for(@user, handle)
      started = Time.current
      grading = if @grader.is_a?(OfflineGrader)
        'Answers are timed and retained for independent review; no automated grade is assigned.'
      else
        "Each answer is timed and graded 1–5 by #{@grader.label} against Rupert’s own data."
      end
      post_notice("🧪 Test run #{@run_id}#{" (#{@set} questions)" unless @set == 'default'}: #{@items.size} questions to @#{handle} (#{model_name}), asked as #{@user.display_name}. #{grading}")
      @record = BatteryRun.create!(run_key: @run_id, set_name: record_set_name, agent: @agent&.handle, model: model_name,
        engine: (@agent ? 'local_gateway' : ModelConfig.current.engine), revision: self.class.revision, status: 'running',
        questions: @items.size, results: [], room: @room, started_at: started)
      @items.each_with_index do |item, index|
        @results << run_item(item, index)
        @record.update!(results: @record.results_list + [result_row(@results.last)])
        @record.tally!
      end
      @record.update!(status: 'done', finished_at: Time.current)
      summary = post_notice(summary_text(Time.current - started))
      summary.toggle_pin!(@user) unless summary.pinned?
      @results
    end

    def self.revision = BuildInfo.current.short_revision

    # The saved name of this run's question set; a run of only some questions is marked so it never counts as the full set.
    # Runs with the answer check (RUPERT_VERIFY) are kept apart: "finance+verify".
    def record_set_name
      name = @cohort ? "#{@run_set}-cohort-#{@cohort.id}" : @run_set
      name = "#{name}+verify" if Verify.enabled_for?(@agent)
      @partial ? "#{name} (part)" : name
    end

    # The same bot, model and question set already finished on this Rupert build, if any.
    def already_done = BatteryRun.already_done(agent: @agent&.handle, model: model_name, set_name: record_set_name, revision: self.class.revision)

    def model_name = (@agent ? ModelConfig.for_local(@agent) : ModelConfig.current).model

    # Markdown for docs: one row per question.
    def report_markdown
      lines = ["### Run #{@run_id}#{" (#{@set})" unless @set == 'default'}: @#{handle} (#{model_name}), review: #{@grader.label}", '',
               '| # | Cadence | Question | Time | Tools | Views | Grade | Grader’s note |', '| --- | --- | --- | --- | --- | --- | --- | --- |']
      @results.each_with_index do |result, index|
        lines << "| #{index + 1} | #{result.item.cadence} | #{result.item.question.tr('|', '/')} | #{format_seconds(result.seconds)} | " \
                 "#{result.tools.join(', ').presence || '—'} | #{view_summary(result).map { |view| view['kind'] }.join(', ').presence || '—'} | " \
                 "#{result.grade&.dig(:score) || '—'} | #{result.grade&.dig(:verdict).to_s.tr('|', '/').tr("\n", ' ')} |"
      end
      lines << '' << summary_text(nil)
      lines.join("\n")
    end

    private

    def run_item(item, index)
      log "[#{index + 1}/#{@items.size}] #{item.cadence}: #{item.question}"
      question = @room.messages.create!(user: @user, body: "@#{handle} #{item.question}",
        meta: { 'battery' => @run_id, 'item' => item.id, 'cadence' => item.cadence })
      reply = @room.messages.create!(author_kind: 'assistant', status: 'pending', activity: @agent ? "Loading #{@agent.name}" : 'Thinking',
        meta: { 'asked_by' => @user.id, 'trigger_id' => question.id, 'agent' => @agent&.handle, 'battery' => @run_id, 'isolated' => true }.compact)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        Timeout.timeout(QUESTION_TIMEOUT, QuestionTimeout) { Agent.new(reply).run }
      rescue QuestionTimeout
        Run.for_reply!(reply).cancel!(user: @user)
        reply.reload.update!(status: 'failed', activity: nil, body: 'Benchmark failed: no answer within 120 seconds.',
          meta: reply.meta.to_h.merge('duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
            'battery_timeout' => true))
      end
      reply.reload
      # Every action card originates as a proposal. A timeout may already have
      # dismissed it, so retain its tool name regardless of its current state.
      proposed_tools = reply.actions_list.filter_map { |action| action['tool'] }.uniq
      dismiss_proposals(reply)
      meta = reply.meta.to_h
      seconds = meta['duration_ms'].to_f / 1000
      load_seconds = (meta['load_ms'].to_f / 1000).round(1).nonzero?
      grade = grade_for(item, reply)
      grade = nil if @grader.is_a?(OfflineGrader)
      post_grade(reply, grade, seconds) if grade
      check = meta['verify']
      check_note = (" · check: #{Array(check['failed']).size} failed, kept #{check['kept']}" if check)
      log "    #{reply.status} in #{format_seconds(seconds)}#{" (#{format_seconds(load_seconds)} model load)" if load_seconds}#{check_note} · tools #{Array(meta['tools']).join(', ').presence || 'none'} · grade #{grade&.dig(:score) || '—'}"
      Result.new(item: item, seconds: seconds, tools: Array(meta['tools']), status: reply.status, answer: reply.body.to_s,
        grade: grade, grading_error: @last_grade_error, tokens_in: meta['tokens_in'], tokens_out: meta['tokens_out'], unverified: Array(meta['unverified']), message_id: reply.id,
        load_seconds: load_seconds, verify: check&.except('draft'), proposed_tools: proposed_tools, views: Array(meta['views']))
    end

    def view_summary(result)
      Array(result.views).filter_map do |view|
        next unless view.is_a?(Hash)

        kind = view['kind'].to_s
        { 'kind' => kind, 'rows' => Array(view['rows']).size, 'unmatched_figures' => view['unchecked'].to_i,
          'adjustable' => %w[table bar_chart line_chart].include?(kind) }
      end
    end

    def result_row(result)
      { 'id' => result.item.id, 'cadence' => result.item.cadence, 'module' => result.item.module, 'question' => result.item.question, 'status' => result.status,
        'seconds' => result.seconds.round(1), 'load_seconds' => result.load_seconds, 'verify' => result.verify, 'tools' => result.tools, 'grade' => result.grade&.dig(:score),
        'verdict' => result.grade&.dig(:verdict).to_s.first(300), 'grading_error' => result.grading_error, 'grader' => @grader.label,
        'unverified' => result.unverified.to_a, 'proposed_tools' => result.proposed_tools.to_a, 'views' => view_summary(result), 'message_id' => result.message_id }
    end

    def grade_for(item, reply)
      @last_grade_error = nil
      return { score: 1, verdict: 'Failed: no answer within 120 seconds.', issues: [] } if reply.meta.to_h['battery_timeout']
      return { score: 1, verdict: "No answer: the reply #{reply.status == 'failed' ? 'failed' : 'was empty'}.", issues: [] } if reply.status != 'done' || reply.body.blank?

      reference = @cohort ? @cohort.reference(item) { reference_for(item) } : reference_for(item)
      raise Grader::Error, 'no reference or authored expectation' if reference.blank? && item.expect.blank?

      @grader.grade(question: item.question, answer: reply.body.to_s, reference: reference, tools_used: Array(reply.meta.to_h['tools']),
        expect: item.expect)
    rescue Grader::Error => e
      log "    grading failed: #{e.message.first(160)}"
      @last_grade_error = 'reference_or_grader_unavailable'
      nil
    end

    # What Rupert's own tools say for this question, so the grader has the truth to compare with.
    def reference_for(item)
      token = Token.new(@user)
      coverage = BatteryCoverage.new(user: @user, items: [])
      evidence = {}
      item.checks.map do |check|
        name = check.is_a?(Hash) ? check['tool'] : check.to_s
        args = (check.is_a?(Hash) ? check['args'].to_h : {}).transform_values { |value| preset_date(value) }
        if %w[where_is how_do_i].include?(name)
          outcome = AskRupert::Tools.new(user: @user).call(name, args)
          raise Grader::Error, "reference lookup #{name} failed or found nothing" if !outcome.ok || outcome.text.to_s.match?(/\ANo (matching page|lesson matches)/)

          text = AskRupert::Redactor.personal(outcome.text)
          raise Grader::Error, "reference lookup #{name} output exceeds the judge limit" if text.length > Grader::REFERENCE_CHARS
          evidence[name] = { 'text' => text, 'links' => outcome.links }
          next "#{name}(#{JSON.generate(args)}):\n#{text}"
        end
        tool = Mcp::Registry.find(name)
        raise Grader::Error, "reference tool #{name} unavailable" unless tool&.read_only && tool.available_to?(token)

        outcome = tool.new(token: token).call(args)
        data = coverage.reference_data(outcome.data, check)
        raise Grader::Error, "reference tool #{name} could not be checked" unless coverage.checkable_data?(data)
        evidence[name] = data
        summary = check.is_a?(Hash) && (check['select_title'].present? || check['select_titles'].present? || check['select_area'].present?) ? '' : outcome.text
        text = AskRupert::Redactor.personal("#{summary}\n#{JSON.generate(data)}")
        raise Grader::Error, "reference tool #{name} output exceeds the judge limit" if text.length > Grader::REFERENCE_CHARS

        "#{name}(#{JSON.generate(args)}):\n#{text}"
      rescue Grader::Error
        raise
      rescue StandardError
        raise Grader::Error, "reference tool #{name} failed"
      end.tap do
        Array(item.needs).each do |need|
          name, path = need.to_s.split(':', 2)
          raise Grader::Error, "reference field #{need} missing" unless evidence.key?(name) && coverage.need_present?(evidence[name], path)
        end
      end.join("\n\n")
    end

    # "last_month.from" → that preset's first day, so the battery file can name moving dates.
    def preset_date(value)
      key, edge = value.to_s.match(/\A(\w+)\.(from|to)\z/)&.captures
      preset = TimeRangePicker.preset(key, Date.current) if key
      preset ? preset.public_send(edge).iso8601 : value
    end

    def post_grade(reply, grade, seconds)
      issues = Array(grade[:issues]).first(3).map { |issue| "\n- #{issue}" }.join
      flagged = Array(reply.meta.to_h['unverified'])
      issues += "\n⚠ Number check: #{flagged.join(', ')} not found in Rupert's data." if flagged.any?
      @room.messages.create!(author_kind: 'system', parent_id: nil,
        body: "Grade #{grade[:score]}/5 for #{bot_name} (#{format_seconds(seconds)}, #{Array(reply.meta.to_h['tools']).join(', ').presence || 'no tools'}): " \
              "#{grade[:verdict]}#{issues}\n— graded by #{@grader.label} in #{format_seconds(grade[:seconds].to_f)}",
        meta: { 'battery' => @run_id, 'grade' => grade[:score], 'graded_message' => reply.id })
    end

    def dismiss_proposals(reply)
      reply.actions_list.select { |action| action['status'] == 'proposed' }.each do |action|
        Actions.decide!(reply, action['id'], user: @user, approve: false)
      end
    end

    def summary_text(elapsed)
      graded = @results.filter_map { |result| result.grade&.dig(:score) }
      times = @results.map(&:seconds).select(&:positive?)
      by_cadence = @results.group_by { |result| result.item.cadence }.map do |cadence, rows|
        scores = rows.filter_map { |row| row.grade&.dig(:score) }
        "#{cadence} #{scores.any? ? format('%.1f', scores.sum.to_f / scores.size) : '—'}"
      end
      [
        "📋 Test run #{@run_id} done: @#{handle} (#{model_name}) answered #{@results.count { |result| result.status == 'done' }}/#{@results.size}.",
        ("Average grade #{format('%.1f', graded.sum.to_f / graded.size)}/5 (#{graded.tally.sort.reverse.map { |score, count| "#{count}× #{score}" }.join(', ')})." if graded.any?),
        "Graded #{graded.size}/#{@results.size}; #{@results.size - graded.size} ungraded.",
        ("Time per answer: average #{format_seconds(times.sum / times.size)}, fastest #{format_seconds(times.min)}, slowest #{format_seconds(times.max)}." if times.any?),
        ("By cadence: #{by_cadence.join(' · ')}." if by_cadence.any?),
        "Number check flagged figures in #{@results.count { |result| result.unverified.to_a.any? }} of #{@results.size} replies; an unflagged reply is not necessarily verified.",
        ("Whole run took #{format_seconds(elapsed)}." if elapsed)
      ].compact.join("\n")
    end

    def post_notice(text) = @room.messages.create!(author_kind: 'system', body: text.first(Message::BODY_MAX), meta: { 'battery' => @run_id })

    def format_seconds(seconds)
      seconds = seconds.to_f
      seconds >= 90 ? "#{(seconds / 60).floor} min #{(seconds % 60).round} s" : "#{seconds.round(1)} s"
    end

    def log(text) = @out&.puts(text)
  end
end
