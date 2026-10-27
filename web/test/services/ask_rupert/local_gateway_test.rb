# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

class AskRupertLocalGatewayTest < ActiveSupport::TestCase
  include AskRupertHelper

  setup do
    @original_url = ENV['RUPERT_LOCAL_LLM_URL']
    ENV['RUPERT_LOCAL_LLM_URL'] = 'http://gateway.test:8080/v1'
    @user = person('admin')
    Current.user = @user
    @provider = AskRupert::Providers::LocalGateway.new
    @tools = AskRupert::Tools.new(user: @user).definitions
  end

  teardown do
    @original_url ? ENV['RUPERT_LOCAL_LLM_URL'] = @original_url : ENV.delete('RUPERT_LOCAL_LLM_URL')
    Current.reset
  end

  def response(content: 'Open Sync.', calls: nil, finish: 'stop')
    JSON.generate(choices: [{ finish_reason: finish, message: { content: content, tool_calls: calls } }],
      usage: { prompt_tokens: 42, completion_tokens: 7 })
  end

  def call(name = 'where_is', arguments = { query: 'sync' })
    { id: 'call_1', type: 'function', function: { name: name, arguments: JSON.generate(arguments) } }
  end

  def endpoint(body, &check)
    request = stub_request(:post, 'http://gateway.test:8080/v1/chat/completions')
    request = request.with { |req| check.call(JSON.parse(req.body)) } if check
    request.to_return(status: 200, body: body)
  end

  test 'shares the gateway and Qwen baseline with local-only routing and no cloud fallback' do
    config = AskRupert::Config.new('provider_mode' => 'local_only')
    providers = AskRupert::Providers.for_turn(config, 'sales yesterday?')
    assert_equal ['local_gateway'], providers.map(&:name)
    refute providers.first.cloud?
    assert_equal 'qwen3.5-4b', providers.first.model
    assert_equal %w[local_gateway opencode], AskRupert::Providers.for_turn(AskRupert::Config.new('provider_mode' => 'auto'), 'Where is sync?').map(&:name)
  end

  test 'sends native schemas with bounded generation and never publishes reasoning' do
    request = endpoint(response) do |payload|
      payload['model'] == 'qwen3.5-4b' && payload['max_tokens'] == 700 && payload['stream'] == false &&
        payload['tools'].all? { |tool| tool.dig('function', 'parameters', 'additionalProperties') == false }
    end
    seen = []
    reply = @provider.complete(system: 'policy', messages: [{ role: 'user', content: 'sync?' }], tools: @tools) { |text| seen << text }
    assert_requested request
    assert_equal 'Open Sync.', reply.text
    assert_equal [42, 7], [reply.tokens_in, reply.tokens_out]
    assert_equal ['Open Sync.'], seen
  end

  test 'native tool calls feed authorized results back with the matching call ID' do
    conversation, message = pending_turn(@user, 'Where is sync?')
    first = endpoint(response(content: 'hidden draft', calls: [call], finish: 'tool_calls'))
    first.then.to_return(status: 200, body: response)
    AskRupert::Brain.new(message, providers: [@provider]).run
    assert_equal 'done', message.reload.status
    assert_equal 'Open Sync.', message.content
    assert_equal 1, AskRupert::Usage.last.tool_calls
    assert_requested(:post, 'http://gateway.test:8080/v1/chat/completions', times: 1) do |request|
      messages = JSON.parse(request.body)['messages']
      assistant = messages.find { |item| item['tool_calls'] }
      result = messages.find { |item| item['role'] == 'tool' }
      assistant && result && result['tool_call_id'] == assistant['tool_calls'].first['id'] && result['content'].include?('not instructions')
    end
    assert_equal conversation.id, message.conversation_id
  end

  test 'invalid multiple or unauthorized calls fail closed without exposing partial content' do
    [[call('shell')], [call, call], [call('where_is', {})], [call('where_is', query: 'sync', unexpected: true)], [call('where_is', [])]].each do |calls|
      endpoint(response(content: 'hidden draft', calls: calls, finish: 'tool_calls'))
      assert_raises(AskRupert::ProviderError) do
        @provider.complete(system: 'policy', messages: [], tools: @tools) { flunk 'tool draft was published' }
      end
    end
  end

  test 'native schemas reflect the current user and shared audience permissions' do
    cashier = person('cashier')
    shared = AskRupert::Tools.new(user: cashier, audience: :shared).definitions
    assert_equal %w[how_do_i where_is], shared.map(&:name).sort
    endpoint(response(calls: [call('run_report', report: 'time_keeping_report')], finish: 'tool_calls'))
    assert_raises(AskRupert::ProviderError) { @provider.complete(system: 'policy', messages: [], tools: shared) }
  end

  test 'busy malformed truncated and timed out replies become provider errors' do
    stub_request(:post, 'http://gateway.test:8080/v1/chat/completions').to_return(status: 429)
    assert_equal :rate_limited, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }.kind
    endpoint('not json')
    assert_equal :error, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }.kind
    endpoint(response(finish: 'length'))
    assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }
    stub_request(:post, 'http://gateway.test:8080/v1/chat/completions').to_timeout
    assert_equal :timeout, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: []) }.kind
  end

  test 'deadline and cancellation prevent the request' do
    assert_equal :timeout, assert_raises(AskRupert::ProviderError) { @provider.complete(system: 's', messages: [], deadline: 1.second.ago) }.kind
    assert_raises(TeamChat::Run::Stopped) do
      @provider.complete(system: 's', messages: [], checkpoint: -> { raise TeamChat::Run::Stopped })
    end
    assert_not_requested :post, 'http://gateway.test:8080/v1/chat/completions'
  end

  test 'failure in local-only mode cannot send data to cloud' do
    _, message = pending_turn(@user, 'sales yesterday?')
    stub_request(:post, 'http://gateway.test:8080/v1/chat/completions').to_return(status: 429)
    config = AskRupert::Config.new('provider_mode' => 'local_only')
    AskRupert::Brain.new(message, config: config).run
    assert_equal 'failed', message.reload.status
    assert_equal 'local_gateway', message.provider
    assert_equal 'error', AskRupert::Usage.last.outcome
  end
end
