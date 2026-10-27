# frozen_string_literal: true

require 'json'
require 'net/http'
require 'timeout'

module AskRupert
  module Providers
    # Reuses TeamChat's single-model llama.cpp gateway. Native calls are translated
    # to Brain's protocol; Tools still validates every call as the signed-in user.
    class LocalGateway
      MAX_INPUT_CHARS = 24_000
      MAX_RESPONSE_BYTES = 131_072
      TIMEOUT = 120
      BASELINE_MODEL = 'qwen3.5-4b'

      def name = 'local_gateway'
      def cloud? = false
      def native_tools? = true
      def configured? = ENV['RUPERT_LOCAL_LLM_URL'].present?
      def model = BASELINE_MODEL

      def complete(system:, messages:, tools: [], deadline: nil, checkpoint: nil)
        raise ProviderError.new('local gateway is not configured', kind: :unavailable) unless configured?

        checkpoint&.call
        seconds = deadline ? [TIMEOUT, deadline - Time.current].min : TIMEOUT
        raise ProviderError.new('local gateway timed out', kind: :timeout) unless seconds.positive?

        instructions = "#{system}\nUse the supplied native function tools instead of writing TOOL_CALL lines."
        definitions = tools.map { |tool| definition(tool) }
        kept = PromptBudget.messages(messages, budget: MAX_INPUT_CHARS - instructions.length - JSON.generate(definitions).length)
        payload = { model: model, stream: false, max_tokens: 700, temperature: 0.2,
                    messages: [{ role: 'system', content: instructions }] + native_messages(kept) }
        if tools.any?
          payload[:tools] = definitions
          payload[:parallel_tool_calls] = false
        end
        uri = URI("#{ENV.fetch('RUPERT_LOCAL_LLM_URL').chomp('/')}/chat/completions")
        request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
        request.body = JSON.generate(payload)
        body = +''
        response = nil
        Timeout.timeout(seconds) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 3, read_timeout: seconds) do |http|
            http.request(request) do |result|
              response = result
              result.read_body do |chunk|
                checkpoint&.call
                body << chunk
                raise ProviderError.new('local gateway response too large', kind: :error) if body.bytesize > MAX_RESPONSE_BYTES
              end
            end
          end
        end
        checkpoint&.call
        unless response.is_a?(Net::HTTPSuccess)
          kind = response.code.to_i == 429 ? :rate_limited : :unavailable
          raise ProviderError.new("local gateway answered #{response.code}", kind: kind)
        end
        data = JSON.parse(body)
        text = reply_text(data.fetch('choices').first, tools)
        yield text if block_given? && !text.start_with?('TOOL_CALL:')
        Reply.new(text: text, tokens_in: data.dig('usage', 'prompt_tokens').to_i,
          tokens_out: data.dig('usage', 'completion_tokens').to_i, provider: name, model: model)
      rescue Timeout::Error
        raise ProviderError.new('local gateway timed out', kind: :timeout)
      rescue SystemCallError, SocketError, IOError, URI::InvalidURIError
        raise ProviderError.new('local gateway unreachable', kind: :unavailable)
      rescue JSON::ParserError, KeyError, NoMethodError, TypeError, ArgumentError
        raise ProviderError.new('invalid local gateway response', kind: :error)
      end

      private

      def definition(tool)
        { type: 'function', function: { name: tool.name, description: tool.description,
          parameters: { type: 'object', properties: tool.properties, required: tool.required, additionalProperties: false } } }
      end

      def native_messages(messages)
        pending = nil
        messages.each_with_index.map do |message, index|
          call = ReplyFormat.parse_call(message[:content]) if message[:role].to_s == 'assistant'
          if call
            pending = "ask_rupert_#{index}"
            { role: 'assistant', content: nil, tool_calls: [{ id: pending, type: 'function',
              function: { name: call['name'], arguments: JSON.generate(call['arguments']) } }] }
          elsif pending
            result = { role: 'tool', tool_call_id: pending, content: message[:content] }
            pending = nil
            result
          else
            { role: message[:role], content: message[:content] }
          end
        end
      end

      def reply_text(choice, tools)
        raise ProviderError.new('local gateway output was truncated', kind: :error) if choice.fetch('finish_reason') == 'length'

        message = choice.fetch('message')
        calls = message['tool_calls']
        if calls.present?
          raise ProviderError.new('local gateway returned multiple tool calls', kind: :error) unless calls.is_a?(Array) && calls.one?

          call = calls.first.fetch('function')
          tool = tools.find { |item| item.name.to_s == call['name'] }
          raise ProviderError.new('local gateway returned an unknown tool', kind: :error) unless tool

          arguments = JSON.parse(call.fetch('arguments'))
          raise ProviderError.new('local gateway returned invalid tool arguments', kind: :error) unless arguments.is_a?(Hash)

          schema = { type: 'object', properties: tool.properties, required: tool.required, additionalProperties: false }
          coerced, problems = Mcp::SchemaValidator.call(schema, arguments)
          raise ProviderError.new('local gateway returned invalid tool arguments', kind: :error) unless problems.empty?

          return "TOOL_CALL: #{JSON.generate(name: tool.name, arguments: coerced)}"
        end
        text = message.fetch('content').to_s.strip
        raise ProviderError.new('local gateway returned no text', kind: :error) if text.empty?

        text
      end
    end
  end
end
