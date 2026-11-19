# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

class AskRupertMlxProviderTest < ActiveSupport::TestCase
  include AskRupertHelper

  URL = 'http://mlx.test:8090/v1/chat/completions'
  ENV_KEYS = %w[RUPERT_MLX_LLM_URL RUPERT_MLX_LLM_MODEL RUPERT_LOCAL_LLM_URL].freeze

  setup do
    @saved = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV['RUPERT_MLX_LLM_URL'] = 'http://mlx.test:8090/v1'
    @user = person('admin')
    Current.user = @user
    @provider = AskRupert::Providers::Mlx.new
    @tools = AskRupert::Tools.new(user: @user).definitions
  end

  teardown do
    ENV_KEYS.each { |key| ENV.delete(key) }
    @saved.each { |key, value| ENV[key] = value }
    Current.reset
  end

  # An OpenAI-style server-sent event stream, as mlx_lm.server writes it.
  def sse(*deltas, finish: 'stop', usage: { prompt_tokens: 40, completion_tokens: 6 })
    events = deltas.map { |delta| { choices: [{ index: 0, delta: delta, finish_reason: nil }] } }
    events << { choices: [{ index: 0, delta: {}, finish_reason: finish }] }
    events << { choices: [], usage: usage }
    events.map { |event| "data: #{JSON.generate(event)}\n\n" }.join + "data: [DONE]\n\n"
  end

  def tool_delta(name = 'where_is', arguments = { query: 'sync' })
    { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: name, arguments: JSON.generate(arguments) } }] }
  end

  def endpoint(body, &check)
    request = stub_request(:post, URL)
    request = request.with { |req| check.call(JSON.parse(req.body)) } if check
    request.to_return(status: 200, body: body, headers: { 'Content-Type' => 'text/event-stream' })
  end

  test 'is off unless its URL is set, so the gateway and Ollama paths are unchanged' do
    ENV.delete('RUPERT_MLX_LLM_URL')
    config = AskRupert::Config.new('provider_mode' => 'local_only')
    assert_equal ['ollama'], AskRupert::Providers.for_turn(config, 'sales?').map(&:name)
    ENV['RUPERT_LOCAL_LLM_URL'] = 'http://gateway.test:8080/v1'
    assert_equal ['local_gateway'], AskRupert::Providers.for_turn(config, 'sales?').map(&:name)
  end

  test 'when set it answers local turns and never falls back to the cloud in local-only mode' do
    ENV['RUPERT_LOCAL_LLM_URL'] = 'http://gateway.test:8080/v1'
    providers = AskRupert::Providers.for_turn(AskRupert::Config.new('provider_mode' => 'local_only'), 'sales yesterday?')
    assert_equal ['mlx'], providers.map(&:name)
    refute providers.first.cloud?
    assert_equal 'default_model', providers.first.model
    assert_equal 'default_model (MLX on this network)', AskRupert::Providers.local_label(AskRupert::Config.new({}))
    ENV['RUPERT_MLX_LLM_MODEL'] = 'qwen3.5-4b'
    assert_equal 'qwen3.5-4b', AskRupert::Providers::Mlx.new.model
  end

  test 'streams the answer with thinking off and the same bounded native schemas' do
    request = endpoint(sse({ role: 'assistant', content: '' }, { reasoning: 'hidden' }, { content: 'Open ' }, { content: 'Sync.' })) do |payload|
      payload['model'] == 'default_model' && payload['stream'] == true && payload['max_tokens'] == 700 &&
        payload.dig('chat_template_kwargs', 'enable_thinking') == false && payload['parallel_tool_calls'] == false &&
        payload['tools'].all? { |tool| tool.dig('function', 'parameters', 'additionalProperties') == false }
    end
    seen = []
    reply = @provider.complete(system: 'policy', messages: [{ role: 'user', content: 'sync?' }], tools: @tools) { |text| seen << text }
    assert_requested request
    assert_equal 'Open Sync.', reply.text
    assert_equal ['Open ', 'Open Sync.'], seen
    assert_equal [40, 6], [reply.tokens_in, reply.tokens_out]
    assert_equal 'mlx', reply.provider
  end

  test 'streamed tool calls are rebuilt, checked and run through Brain as the signed-in user' do
    _conversation, message = pending_turn(@user, 'Where is sync?')
    endpoint(sse(tool_delta, finish: 'tool_calls')).then.to_return(status: 200, body: sse({ content: 'Open Sync.' }))
    AskRupert::Brain.new(message, providers: [@provider]).run
    assert_equal 'done', message.reload.status
    assert_equal 'Open Sync.', message.content
    assert_equal 'mlx', message.provider
    assert_equal 1, AskRupert::Usage.last.tool_calls
  end

  test 'arguments split across chunks are joined before checking' do
    parts = [{ tool_calls: [{ index: 0, id: 'c', type: 'function', function: { name: 'where_is', arguments: '{"query":' } }] },
             { tool_calls: [{ index: 0, function: { arguments: '"sync"}' } }] }]
    endpoint(sse(*parts, finish: 'tool_calls'))
    reply = @provider.complete(system: 's', messages: [], tools: @tools) { flunk 'a tool call was published' }
    assert_equal 'TOOL_CALL: {"name":"where_is","arguments":{"query":"sync"}}', reply.text
  end

  test 'unknown, multiple, invalid and truncated replies fail closed' do
    second = { tool_calls: [{ index: 1, id: 'c2', type: 'function', function: { name: 'where_is', arguments: '{"query":"x"}' } }] }
    [sse(tool_delta('shell'), finish: 'tool_calls'), sse(tool_delta, second, finish: 'tool_calls'),
     sse(tool_delta('where_is', {}), finish: 'tool_calls'), sse(tool_delta('where_is', query: 'x', extra: 1), finish: 'tool_calls'),
     sse({ content: 'cut off' }, finish: 'length'), sse({ reasoning: 'only thinking' })].each do |body|
      endpoint(body)
      assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: [], tools: @tools) }
    end
  end

  test 'server errors, a missing model and timeouts become provider errors' do
    stub_request(:post, URL).to_return(status: 429)
    assert_equal :rate_limited, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }.kind
    stub_request(:post, URL).to_return(status: 404, body: 'Repository Not Found')
    assert_equal :unavailable, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }.kind
    stub_request(:post, URL).to_timeout
    assert_equal :timeout, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }.kind
    assert_equal :timeout, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: [], deadline: 1.second.ago) }.kind
  end
end
