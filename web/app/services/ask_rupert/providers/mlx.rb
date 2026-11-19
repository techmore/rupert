# frozen_string_literal: true

require 'json'
require 'net/http'
require 'timeout'

module AskRupert
  module Providers
    # Experimental: Ask Rupert's local model served by Apple's MLX (`mlx_lm.server`)
    # on an Apple-silicon machine. Off unless RUPERT_MLX_LLM_URL is set, so the
    # llama.cpp gateway and Ollama paths are unchanged. See docs/ai/local-llm-backends.md.
    #
    # Same native tool schemas, budget and checks as LocalGateway (Tools still
    # validates every call as the signed-in user). Two differences: the answer
    # streams into the panel, and thinking is switched off per request, because
    # mlx_lm.server loads whatever the request names as `model`.
    class Mlx < LocalGateway
      DEFAULT_MODEL = 'default_model' # mlx_lm.server's name for the model it was started with

      def name = 'mlx'
      def configured? = ENV['RUPERT_MLX_LLM_URL'].present?
      def model = ENV['RUPERT_MLX_LLM_MODEL'].presence || DEFAULT_MODEL

      def complete(system:, messages:, tools: [], deadline: nil, checkpoint: nil)
        raise ProviderError.new('MLX server is not configured', kind: :unavailable) unless configured?

        checkpoint&.call
        seconds = deadline ? [TIMEOUT, deadline - Time.current].min : TIMEOUT
        raise ProviderError.new('MLX server timed out', kind: :timeout) unless seconds.positive?

        uri = URI("#{ENV.fetch('RUPERT_MLX_LLM_URL').chomp('/')}/chat/completions")
        request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
        request.body = JSON.generate(payload(system, messages, tools))
        stream = { text: +'', calls: {}, finish: nil, usage: {}, bytes: 0 }
        Timeout.timeout(seconds) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 3, read_timeout: seconds) do |http|
            http.request(request) do |response|
              unless response.is_a?(Net::HTTPSuccess)
                raise ProviderError.new("MLX server answered #{response.code}", kind: response.code.to_i == 429 ? :rate_limited : :unavailable)
              end

              buffer = +''
              response.read_body do |chunk|
                checkpoint&.call
                stream[:bytes] += chunk.bytesize
                raise ProviderError.new('MLX server response too large', kind: :error) if stream[:bytes] > MAX_RESPONSE_BYTES

                buffer << chunk
                while (line = buffer.slice!(/\A[^\n]*\n/))
                  grew = read_event(line, stream)
                  yield stream[:text].dup if grew && block_given? && stream[:calls].empty?
                end
              end
            end
          end
        end
        checkpoint&.call
        text = reply_text(choice(stream), tools)
        Reply.new(text: text, tokens_in: stream[:usage]['prompt_tokens'].to_i, tokens_out: stream[:usage]['completion_tokens'].to_i,
          provider: name, model: model)
      rescue Timeout::Error
        raise ProviderError.new('MLX server timed out', kind: :timeout)
      rescue SystemCallError, SocketError, IOError, URI::InvalidURIError
        raise ProviderError.new('MLX server unreachable', kind: :unavailable)
      rescue JSON::ParserError, KeyError, NoMethodError, TypeError, ArgumentError
        raise ProviderError.new('invalid MLX server response', kind: :error)
      end

      private

      def payload(system, messages, tools)
        instructions = "#{system}\nUse the supplied native function tools instead of writing TOOL_CALL lines."
        definitions = tools.map { |tool| definition(tool) }
        kept = PromptBudget.messages(messages, budget: MAX_INPUT_CHARS - instructions.length - JSON.generate(definitions).length)
        body = { model: model, stream: true, stream_options: { include_usage: true }, max_tokens: 700, temperature: 0.2,
                 chat_template_kwargs: { enable_thinking: false },
                 messages: [{ role: 'system', content: instructions }] + native_messages(kept) }
        if tools.any?
          body[:tools] = definitions
          body[:parallel_tool_calls] = false
        end
        body
      end

      # One server-sent event. Returns true when the visible answer grew. Reasoning is never kept.
      def read_event(line, stream)
        data = line.strip.delete_prefix('data:').strip
        return false unless line.lstrip.start_with?('data:') && data.present? && data != '[DONE]'

        event = JSON.parse(data)
        stream[:usage] = event['usage'] if event['usage'].is_a?(Hash)
        choice = Array(event['choices']).first
        return false unless choice.is_a?(Hash)

        stream[:finish] = choice['finish_reason'] if choice['finish_reason']
        delta = choice['delta'] || {}
        Array(delta['tool_calls']).each do |part|
          slot = stream[:calls][part['index'] || stream[:calls].length] ||= { 'name' => +'', 'arguments' => +'' }
          function = part['function'] || {}
          slot['name'] << function['name'].to_s
          arguments = function['arguments']
          slot['arguments'] << (arguments.is_a?(String) ? arguments : JSON.generate(arguments || {}))
        end
        return false if delta['content'].to_s.empty?

        stream[:text] << delta['content']
        true
      end

      # The streamed reply in the shape LocalGateway#reply_text checks.
      def choice(stream)
        calls = stream[:calls].values.map { |slot| { 'type' => 'function', 'function' => slot } }
        { 'finish_reason' => stream[:finish] || 'stop', 'message' => { 'content' => stream[:text], 'tool_calls' => calls.presence } }
      end
    end
  end
end
