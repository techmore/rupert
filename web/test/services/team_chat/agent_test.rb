# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatAgentTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
  end

  teardown { Current.reset }

  def ask(text, parent_id: nil)
    TeamChat::Post.call(room: @room, user: @user, body: text, parent_id: parent_id).reply
  end

  test 'a mention gets a pending reply; a plain message does not' do
    assert_nil ask('hello team')
    reply = ask('@rupert where are timesheets?')
    assert reply.pending?
    assert_equal 'assistant', reply.author_kind
    assert_equal @user.id, reply.meta['asked_by']
  end

  test 'the reply calls a Rupert tool natively and streams the answer into the room' do
    requests = script_model({ tool: 'where_is', arguments: { query: 'timesheets' } }, { text: 'Timesheets are under Team. Open [Timesheets](/people/timesheets).' })
    reply = ask('@rupert where are timesheets? Also explain the approval workflow.')

    TeamChat::Agent.new(reply, config: team_chat_config).run
    reply.reload

    assert_equal 'done', reply.status
    assert_includes reply.body, '[Timesheets](/people/timesheets)'
    assert_equal ['where_is'], reply.meta['tools']
    assert_equal 'ok', reply.meta['outcome']
    run = AiAgentRun.where(agent: 'team_chat').last
    assert_equal ['test-model', 'ok'], [run.model, run.outcome]
    assert_equal 2, requests.size
    first = requests.first
    assert first['stream']
    assert_includes first['tools'].map { |tool| tool.dig('function', 'name') }, 'sales_summary'
    assert_equal 'system', first['messages'].first['role']
    assert_includes first['messages'].first['content'], 'You are Rupert'
    assert_match(/: @rupert where are timesheets\? Also explain the approval workflow\.\z/, first['messages'].last['content'])
    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert tool_message, 'the tool result goes back to the model'
  end

  test 'financial drafts are replaced with typed source period currency and meaning' do
    order = Core::Order.create!(source: 'shopify', source_order_id: 'nc-1', occurred_at: 1.day.ago.change(hour: 12), gross_cents: 21_483, tax_cents: 0, currency: 'USD')
    order.mark_paid!
    requests = script_model({ tool: 'sales_summary', arguments: { from: (Date.current - 1).iso8601, to: (Date.current - 1).iso8601 } },
      { text: 'Yesterday: $214.83 from 1 order, about $215. Up 12% on the day before, so roughly $999.99 this week.' })
    reply = ask('@rupert how were sales yesterday?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_nil reply.reload.meta['unverified']
    assert reply.as_payload(viewer: @user)[:figures_checked], 'the facts Ruby listed come straight from Rupert'
    assert_includes reply.body, '214.83 USD'
    assert_includes reply.body, 'Gross sales'
    assert_includes reply.body, 'shopify canonical orders'
    assert_not_includes reply.body, '999.99'
    assert_not_includes reply.body, '12%'
    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert_includes tool_message['content'], '"value":"214.83"'
    assert_includes requests.first['messages'].first['content'], 'Never add, subtract, average, convert'
  end

  test 'a reply whose figures all come from its tools has nothing flagged' do
    script_model({ text: 'Nothing to report.' })
    reply = ask('@rupert anything new?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_nil reply.reload.meta['unverified']
    assert_nil reply.as_payload(viewer: @user)[:unverified]
    assert_not reply.as_payload(viewer: @user)[:figures_checked], 'no tools, so nothing was checked'
  end

  test 'figures checked shows only for tool answers whose figures were all found' do
    script_model({ tool: 'where_is', arguments: { query: 'timesheets' } }, { text: 'Timesheets are under Team.' })
    reply = ask('@rupert where are timesheets?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal ['where_is'], reply.reload.meta['tools']
    assert_nil reply.meta['figures_checked'], 'an answer with no figures makes no claim about them'

    meta = reply.meta.merge('figures_checked' => true)
    reply.update_columns(meta: meta)
    assert reply.reload.as_payload(viewer: @user)[:figures_checked]
    reply.update_columns(meta: meta.merge('unverified' => ['$12.00']))
    assert_not reply.reload.as_payload(viewer: @user)[:figures_checked]
    reply.update_columns(meta: meta.merge('tools' => []))
    assert_not reply.reload.as_payload(viewer: @user)[:figures_checked]
    reply.update_columns(meta: meta, status: 'pending')
    assert_not reply.reload.as_payload(viewer: @user)[:figures_checked]
  end

  test 'a write tool only proposes; approving runs it as the approver and posts a notice' do
    script_model({ tool: 'create_task', arguments: { title: 'Recount the tea shelf', priority: 'high' } },
      { text: 'I proposed the task; approve it below.' })
    reply = ask('@rupert make a task to recount the tea shelf')

    assert_no_difference -> { Projects::Task.count } do
      TeamChat::Agent.new(reply, config: team_chat_config).run
    end
    action = reply.reload.actions_list.first
    assert_equal 'proposed', action['status']
    assert_equal 'Create task “Recount the tea shelf” (high)', action['summary']

    assert_difference -> { Projects::Task.count }, 1 do
      TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: true)
    end
    assert_equal 'done', reply.reload.actions_list.first['status']
    notice = @room.messages.where(author_kind: 'system').last
    assert_match(/approved: Created task #\d+/, notice.body)
    assert_no_difference -> { Projects::Task.count } do
      assert_equal 'done', TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: true)['status']
    end
  end

  test 'assigning a task privately preserves the assignee without notifying them into the private room' do
    jan = User.create!(tenant: @tenant, email: 'jan.tester@example.com', name: 'Jan Tester', role: @user.role, password: 'password123')
    task = Projects::Task.create!(title: 'Count the tea shelf', priority: 'medium')
    script_model({ tool: 'update_task', arguments: { task_id: task.id, assignee: 'Jan', due_on: '2026-10-30', priority: 'high' } },
      { text: 'Proposed: give it to Jan for Friday.' })
    reply = ask('@rupert assign the tea shelf count to Jan, due Friday, high priority')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    action = reply.reload.actions_list.first
    assert_equal 'proposed', action['status']
    assert_equal "Task ##{task.id} “Count the tea shelf”: assign to Jan Tester, priority high, due 2026-10-30", action['summary']
    assert_equal 'jan.tester@example.com', action.dig('arguments', 'assignee')
    assert_nil task.reload.assignee_id

    TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: true)
    task.reload
    assert_equal [jan.id.to_s, 'high', Date.new(2026, 10, 30)], [task.assignee_id, task.priority, task.due_on]
    notice = @room.messages.where(author_kind: 'system').last
    assert_match(/approved: Updated task ##{task.id}/, notice.body)
    assert_empty notice.mention_ids
    assert_not @room.visible_to?(jan)
  end

  test 'a name that matches two people is sent back to the model to ask which one' do
    2.times { |index| User.create!(tenant: @tenant, email: "sam#{index}@example.com", name: 'Sam Twin', role: @user.role, password: 'password123') }
    requests = script_model({ tool: 'create_task', arguments: { title: 'Restock', assignee: 'Sam Twin' } }, { text: 'Which Sam?' })
    reply = ask('@rupert make a restock task for Sam Twin')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_empty reply.reload.actions_list
    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert_match(/matches 2 people: Sam Twin \(sam0@…\), Sam Twin \(sam1@…\)/, tool_message['content'])
  end

  test 'a dismissed proposal runs nothing' do
    script_model({ tool: 'create_task', arguments: { title: 'Nope' } }, { text: 'Proposed.' })
    reply = ask('@rupert task please')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    action = reply.reload.actions_list.first
    assert_no_difference -> { Projects::Task.count } do
      TeamChat::Actions.decide!(reply, action['id'], user: @user, approve: false)
    end
    assert_equal 'dismissed', reply.reload.actions_list.first['status']
  end

  test 'the thread is the context when the question is asked in a thread' do
    root = @room.messages.create!(user: @user, body: 'Inventory count tonight?')
    @room.messages.create!(user: @user, body: 'Something unrelated at top level')
    requests = script_model({ text: 'Yes.' })
    reply = ask('@rupert is that on the schedule?', parent_id: root.id)
    assert_equal root.id, reply.parent_id

    TeamChat::Agent.new(reply, config: team_chat_config).run
    contents = requests.first['messages'].drop(1).pluck('content').join("\n")
    assert_includes contents, 'Inventory count tonight?'
    assert_not_includes contents, 'Something unrelated'
  end

  test 'a refused credential becomes a friendly failure' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 401, body: { error: { message: 'bad key' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    reply = ask('@rupert hi')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    reply.reload
    assert_equal 'failed', reply.status
    assert_match(/credential was refused/, reply.body)
  end

  test 'opencode go sends the session header and the stored opencode key' do
    Dir.mktmpdir do |dir|
      auth = File.join(dir, 'auth.json')
      File.write(auth, JSON.generate('opencode-go' => { 'type' => 'api', 'key' => 'go-key' }))
      config = TeamChat::ModelConfig.new({}, auth_file: auth)
      assert_equal 'opencode_go', config.engine
      assert config.configured?
      stub = stub_request(:post, "#{TeamChat::ModelConfig::OPENCODE_GO_BASE}/chat/completions")
             .with(headers: { 'Authorization' => 'Bearer go-key', 'X-Opencode-Session' => "rupert-room-#{@room.id}" })
             .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Hi!'))
      reply = ask('@rupert hi')
      TeamChat::Agent.new(reply, config: config).run
      assert_requested stub
      assert_equal 'Hi!', reply.reload.body
    end
  end

  test 'model config picks ollama when only a local model is set, and the CLI otherwise' do
    Dir.mktmpdir do |dir|
      none = File.join(dir, 'missing.json')
      local = TeamChat::ModelConfig.new({ 'OLLAMA_URL' => 'http://127.0.0.1:11434', 'ASK_RUPERT_LOCAL_MODEL' => 'qwen3.5:4b' }, auth_file: none)
      assert_equal 'ollama', local.engine
      assert_equal 'http://127.0.0.1:11434/v1', local.api_base
      assert local.local?
      assert_equal 'opencode_cli', TeamChat::ModelConfig.new({}, auth_file: none).engine
    end
  end

  test 'links to pages Rupert does not have become plain text' do
    script_model({ text: 'See [Alerts](/inventory/alerts) and [Timesheets](/people/timesheets) or [Home](/).' })
    reply = ask('@rupert where?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'See Alerts and [Timesheets](/people/timesheets) or [Home](/).', reply.reload.body
  end

  test 'local_gateway sends @rupert to the rupert-llm gateway with long timeouts and no key' do
    config = TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'local_gateway', 'RUPERT_CHAT_MODEL' => 'qwen3.5-4b',
                                         'RUPERT_LOCAL_LLM_URL' => 'http://10.0.0.7:8080/v1/' })
    assert config.configured?
    assert config.local?
    assert_equal 'http://10.0.0.7:8080/v1', config.api_base
    assert_equal 'qwen3.5-4b on this server', config.label
    assert_match(/nothing leaves it/, config.disclosure)
    stub = stub_request(:post, 'http://10.0.0.7:8080/v1/chat/completions')
           .with { |request| JSON.parse(request.body)['model'] == 'qwen3.5-4b' && JSON.parse(request.body)['messages'].first['role'] == 'system' }
           .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Local hello.'))
    reply = ask('@rupert hi')
    assert_no_difference -> { AiAgentRun.count } do
      TeamChat::Agent.new(reply, config: config).run
    end
    assert_requested stub
    assert_equal 'Local hello.', reply.reload.body
  end

  test 'a refused model hands over to the configured fallback, and the answer says who answered and what it replaced' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 401, body: { error: { message: 'bad key' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    gateway = stub_request(:post, 'http://gateway.test/v1/chat/completions')
              .with { |request| JSON.parse(request.body)['model'] == 'qwen-test' }
              .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: sse_for(text: 'Fallback hello.'))
    config = team_chat_config('RUPERT_CHAT_FALLBACK' => 'local_gateway:qwen-test', 'RUPERT_LOCAL_LLM_URL' => 'http://gateway.test/v1')
    reply = ask('@rupert hi')
    TeamChat::Agent.new(reply, config: config).run
    reply.reload

    assert_requested gateway
    assert_equal ['done', 'Fallback hello.'], [reply.status, reply.body]
    assert_equal ['local_gateway', 'qwen-test'], reply.meta.values_at('engine', 'model')
    assert_equal [{ 'engine' => 'openai', 'model' => 'test-model', 'failure' => 'unauthorized' }], reply.meta['fallback_from']
    assert_equal({ seconds: reply.answer_timing[:seconds], model: 'qwen-test', fallback_from: ['OpenAI-compatible'], where: 'local' }, reply.answer_timing)
    run = TeamChat::Run.unscoped.find_by(message_id: reply.id)
    fallback = TeamChat::Telemetry.unscoped.where(run_id: run.id, kind: 'fallback').sole
    assert_equal({ 'from_engine' => 'openai', 'to_engine' => 'local_gateway', 'failure' => 'unauthorized' }, fallback.facts.slice('from_engine', 'to_engine', 'failure'))
  end

  test 'a model the instance picked explicitly has no fallback unless one is configured' do
    stub_request(:post, "#{LLM_BASE}/chat/completions").to_return(status: 401, body: { error: { message: 'bad key' } }.to_json, headers: { 'Content-Type' => 'application/json' })
    reply = ask('@rupert hi')
    TeamChat::Agent.new(reply, config: team_chat_config('RUPERT_LOCAL_LLM_URL' => 'http://gateway.test/v1')).run
    reply.reload
    assert_equal 'failed', reply.status
    assert_nil reply.meta['fallback_from']
  end

  test 'model config lists fallbacks in order and leaves out unconfigured or repeated ones' do
    Dir.mktmpdir do |dir|
      auth = File.join(dir, 'auth.json')
      File.write(auth, JSON.generate('opencode-go' => { 'type' => 'api', 'key' => 'go-key' }))
      auto = TeamChat::ModelConfig.new({}, auth_file: auth)
      assert_equal ['opencode_cli'], auto.fallbacks.map(&:engine)
      assert_empty TeamChat::ModelConfig.new({ 'RUPERT_CHAT_FALLBACK' => 'none' }, auth_file: auth).fallbacks
      assert_empty TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'opencode_go' }, auth_file: auth).fallbacks

      chosen = TeamChat::ModelConfig.new({ 'RUPERT_CHAT_PROVIDER' => 'opencode_go', 'RUPERT_LOCAL_LLM_URL' => 'http://gateway.test/v1',
                                           'RUPERT_CHAT_FALLBACK' => 'opencode_go, ollama, local_gateway:qwen-test, bogus, opencode_cli, local_gateway:qwen-test' }, auth_file: auth)
      assert_equal [%w[local_gateway qwen-test], ['opencode_cli', nil]], chosen.fallbacks.map { |config| [config.engine, config.model] }
      assert_equal 'http://gateway.test/v1', chosen.fallbacks.first.api_base
      assert_empty chosen.fallbacks.first.fallbacks
    end
  end

  test 'each answer names the provider that answered' do
    asked = @room.messages.create!(user: @user, body: '@rupert hi')
    reply = @room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Hi.',
      meta: { 'asked_by' => @user.id, 'trigger_id' => asked.id, 'engine' => 'opencode_go', 'model' => 'deepseek-v4.1-flash', 'duration_ms' => 4_200 })
    assert_equal({ seconds: 4.2, model: 'deepseek-v4.1-flash', provider: 'OpenCode Go', where: 'cloud' }, reply.answer_timing)
  end
end
