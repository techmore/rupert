# frozen_string_literal: true

require 'digest'
require 'json'

module WebMcp
  # Runs one browser tool call as the signed-in person and returns a result in
  # the MCP shape ({content, structuredContent, isError}), which the page hands
  # back to the assistant unchanged.
  #
  # Every call is audited (tool, outcome, duration, a SHA-256 of the arguments,
  # whether the person confirmed) — never the arguments or results.
  class Runner
    MAX_RESULT_BYTES = Mcp::Server::MAX_RESULT_BYTES
    SECRET = AskRupert::Redactor::SECRET
    EMAIL = AskRupert::Redactor::EMAIL

    Result = Struct.new(:status, :payload, keyword_init: true)

    def initialize(user:, client: nil)
      @user = user
      @client = client.to_s.gsub(/[^\x20-\x7e]/, '?').first(120).presence
    end

    def call(name, arguments, confirmed: false)
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @name = name.to_s.gsub(/[^\w]/, '?').first(64)
      @confirmed = confirmed
      args = arguments.is_a?(Hash) ? arguments.deep_stringify_keys : {}
      @dry_run = args['dry_run'] == true
      @fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical(args)))

      return failure(404, 'unknown_tool', "No browser tool named #{@name} is available to you here.") unless Registry.available?(@user, @name)

      if Registry.confirm?(@name) && args['dry_run'] != true && !confirmed
        return failure(428, 'confirmation_required', 'This tool changes data in Rupert. The person must confirm it on screen first; nothing was saved.')
      end

      Registry.lookup?(@name) ? run_lookup(args) : run_tool(args)
    rescue Mcp::ToolError => e
      failure(422, e.kind.presence || 'tool_error', e.message.to_s.first(400))
    rescue ActiveRecord::RecordNotFound
      failure(404, 'not_found', 'The record you asked for does not exist in this workspace.')
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { webmcp_tool: @name })
      failure(500, 'internal_error', 'Rupert could not complete this tool call. It has been logged for the owner; try again later or open the page itself.')
    end

    private

    def run_lookup(args)
      found = AskRupert::Tools.new(user: @user).call(@name, args)
      return failure(422, 'tool_error', found.text.to_s.first(400)) unless found.ok

      success(found.text, { links: found.links || [] })
    end

    def run_tool(args)
      tool = Registry.mcp_tool(@name)
      coerced, problems = Mcp::SchemaValidator.call(tool.input_schema, args)
      return failure(422, 'invalid_arguments', "Invalid arguments for #{@name}: #{problems.first(5).join(' ')}") if problems.any?

      outcome = tool.new(token: SessionToken.new(@user, write: Registry.write_scope(@name))).call(coerced)
      success(outcome.text, outcome.data)
    end

    def success(text, data)
      data = scrub(data)
      if JSON.generate(data).bytesize > MAX_RESULT_BYTES
        return failure(422, 'too_large', 'The result was too large to return. Use a narrower date range, filters, or a smaller per_page.')
      end

      record('ok')
      Result.new(status: 200, payload: { content: [{ type: 'text', text: scrub(text.to_s) }], structuredContent: data, isError: false })
    end

    def failure(status, kind, message)
      record(kind)
      Result.new(status: status, payload: { content: [{ type: 'text', text: message }], isError: true, error: kind })
    end

    # Keys, tokens and email addresses never leave Rupert through a tool result, even when someone typed
    # one into a task or item name. (Dates and amounts are left alone, so the data stays exact.)
    def scrub(value)
      case value
      when String then value.scrub('').gsub(SECRET, '[secret removed]').gsub(EMAIL, '[email]')
      when Hash then value.to_h { |key, inner| [key, scrub(inner)] }
      when Array then value.map { |inner| scrub(inner) }
      else value
      end
    end

    def canonical(value)
      case value
      when Hash then value.sort_by { |key, _| key.to_s }.map { |key, inner| [key.to_s, canonical(inner)] }
      when Array then value.map { |inner| canonical(inner) }
      else value
      end
    end

    def record(outcome)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000).round
      ActivityLogger.log('webmcp_tool_call', actor: @user,
        details: "tool=#{@name}; outcome=#{outcome}; duration_ms=#{ms}; confirmed=#{@confirmed ? 'yes' : 'no'}#{'; dry_run=yes' if @dry_run}; args_sha256=#{@fingerprint}#{"; client=#{@client}" if @client}")
      OpsLog.event('webmcp_tool_call', level: outcome == 'ok' ? :info : :warn, tool: @name, outcome: outcome, duration_ms: ms,
        user_id: @user&.id, tenant_id: @user&.tenant_id, confirmed: @confirmed ? true : false, args_sha256: @fingerprint, persist: outcome == 'internal_error')
    end
  end
end
