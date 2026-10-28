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

  test 'an operational status asserted without a lookup is not presented as checked' do
    script_model({ text: 'There are no reconciliation follow-ups open.' })
    reply = ask('@rupert are any reconciliation follow-ups open?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal TeamChat::Agent::UNCHECKED_RECORDS, reply.reload.body
    assert_empty reply.meta['tools']
  end

  test 'an unrelated compliance lookup does not answer a reconciliation queue question' do
    compliance = { items: [{ title: 'Books closed', area: 'Books', status: 'watch', detail: 'Review needed' }] }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: compliance))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'Everything is clear.' })
    reply = ask('@rupert Are reconciliation follow-ups open?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'I could not verify the requested queue count from the available records.', reply.reload.body
    assert_includes reply.meta['tools'], 'compliance_check'
  end

  test 'document retention requests include healthy results and select the named row' do
    data = { items: [{ title: 'Other', area: 'Books', status: 'watch', detail: 'Unrelated' },
                     { title: 'Google Drive document retention', area: 'Records', status: 'ok', detail: 'Connected' }] }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: data))
    script_model({ tool: 'compliance_check', arguments: { include_ok: false } }, { text: 'I checked.' })
    reply = ask('@rupert Is our document retention to Google Drive working?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'Recorded document-retention status (ok): Connected', reply.reload.body
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal true, entry.dig('arguments', 'include_ok')
    assert_equal false, entry.dig('original_arguments', 'include_ok')
  end

  test 'month close answers prioritize the lock and preserve changed-after-lock status' do
    unrelated = 25.times.map { |i| { title: "Other #{i}", area: 'Books', status: 'watch', detail: 'Other' } }
    rows = [{ title: 'September 2026: Every day approved', area: 'Month close', status: 'watch', detail: '0 of 30 days approved' },
            { title: 'September 2026: Lock the month', area: 'Month close', status: 'watch', detail: 'You can lock now with a note about what is still open, or finish the steps above first.' }]
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: { items: unrelated + rows }))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'Everything blocks closing.' })
    reply = ask("@rupert Are last month's books closed? What is still open?")
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'September 2026: Not locked.'
    assert_includes reply.body, 'You can lock now with a note'
    assert_includes reply.body, 'Every day approved'
    assert_not_includes reply.body, 'Other 0'
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal true, entry.dig('arguments', 'include_ok')

    rows.last.merge!(status: 'fix', detail: 'Locked, but records changed afterwards: sales.')
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: { items: rows }))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'Not locked.' })
    reply = ask("@rupert Are last month's books closed? What is still open?")
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'Locked, but records changed after the lock.'

    rows.pop
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: { items: rows }))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'It is locked.' })
    reply = ask("@rupert Are last month's books closed? What is still open?")
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'I could not verify the month-close checklist.', reply.reload.body
    assert_nil TeamChat::ComplianceEvidence.close_scope("Are last month's books closed and how did sales do?")
    assert_equal 'Month close', TeamChat::ComplianceEvidence.close_scope('Are the books for last month locked?')
    assert_equal 'Month close', TeamChat::ComplianceEvidence.close_scope('Is last month closed in the books? What is left to do?')
  end

  test 'a missing retention record cannot be treated as a healthy connection' do
    data = { items: [{ title: 'Other', area: 'Books', status: 'watch', detail: 'Unrelated' }] }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: data))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'The drive is connected.' })
    reply = ask('@rupert Is our document retention to Google Drive working?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'I could not verify the recorded Google Drive document-retention status.', reply.reload.body
  end

  test 'timesheet status includes ok rows and never infers zero from a missing row' do
    data = { items: [{ title: 'Timesheets awaiting approval', area: 'People', status: 'ok', count: 0 }] }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: data))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'I checked.' })
    reply = ask('@rupert Are there timesheets waiting for approval?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'Recorded non-demo submitted timesheets awaiting approval: 0.', reply.reload.body
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal true, entry.dig('arguments', 'include_ok')

    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: { items: [] }))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'No timesheets are waiting.' })
    reply = ask('@rupert Are there timesheets waiting for approval?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'I could not verify the requested compliance count.', reply.reload.body
  end

  test 'a mixed timesheet and backup request does not mistake daily book approvals for timesheets' do
    data = { items: [{ title: 'Timesheets awaiting approval', area: 'People', status: 'ok', count: 0 },
                     { title: 'Recent days have been approved by a person', area: 'Books', status: 'watch', count: 2 }] }
    backup = { drive: { fresh: true, fresh_within_hours: 8, last_success_age_hours: 2 } }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: data))
    Mcp::Tools::BackupFreshness.stubs(:available_to?).returns(true)
    Mcp::Tools::BackupFreshness.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'backup', data: backup))
    script_model({ tool: 'compliance_check', arguments: {} }, { tool: 'backup_freshness', arguments: {} }, { text: 'Two timesheets are waiting.' })
    reply = ask('@rupert Are there timesheets waiting for approval and are backups current?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Recorded non-demo submitted timesheets awaiting approval: 0.'
    assert_includes reply.body, 'last verified Google Drive backup was within the last 8 hours'
    assert_not_includes reply.body, 'Two timesheets'

    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'Backups are current.' })
    reply = ask('@rupert Are there timesheets waiting for approval and are backups current?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'I could not verify Google Drive backup freshness.'
  end

  test 'a mixed retention and backup request keeps the two records distinct' do
    data = { items: [{ title: 'Google Drive document retention', area: 'Records', status: 'watch', detail: 'Not connected' }] }
    backup = { drive: { fresh: false, fresh_within_hours: 8, last_success_age_hours: 12 } }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: data))
    Mcp::Tools::BackupFreshness.stubs(:available_to?).returns(true)
    Mcp::Tools::BackupFreshness.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'backup', data: backup))
    script_model({ tool: 'compliance_check', arguments: {} }, { tool: 'backup_freshness', arguments: {} }, { text: 'Both are connected.' })
    reply = ask('@rupert Is our document retention to Google Drive working and are backups current?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Recorded document-retention status (watch): Not connected'
    assert_includes reply.body, 'last verified Google Drive backup was more than 8 hours ago'
    assert_not_includes reply.body, 'Both are connected'
  end

  test 'retention status drafts are not streamed before verification' do
    reply = ask('@rupert Is our document retention to Google Drive working?')
    agent = TeamChat::Agent.new(reply, config: team_chat_config)
    agent.stubs(:request_text).returns('Is our document retention to Google Drive working?')
    execution = mock
    execution.expects(:write_reply!).never
    agent.instance_variable_set(:@execution, execution)

    agent.send(:publish, 'The drive is connected.')
  end

  test 'a conceptual question remains answerable without a record lookup' do
    script_model({ text: 'A task is an item of work.' })
    reply = ask('@rupert what is a task?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'A task is an item of work.', reply.reload.body
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
    assert_includes first['messages'].first['content'], 'do not propose it or offer it as an alternative'
    assert_match(/: @rupert where are timesheets\? Also explain the approval workflow\.\z/, first['messages'].last['content'])
    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert tool_message, 'the tool result goes back to the model'
  end

  test 'after the tool budget the final generation cannot request another tool' do
    calls = Array.new(TeamChat::Toolbox::MAX_CALLS) do |i|
      { tool: 'where_is', arguments: { query: 'timesheets' }, id: "call_#{i}" }
    end
    requests = script_model(*calls, { text: 'Timesheets are under Team.' })
    reply = ask('@rupert where are timesheets? Also explain the approval workflow.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'done', reply.reload.status
    assert_equal TeamChat::Toolbox::MAX_CALLS + 1, requests.size
    assert_equal 'none', requests.last['tool_choice']
    assert_equal TeamChat::Toolbox::MAX_CALLS, TeamChat::Run.find_by!(message_id: reply.id).tool_results.size
  end

  test 'malformed tool markup falls back to scoped task and inventory evidence' do
    Projects::Task.create!(title: 'Recount tea shelf', priority: 'high')
    script_model({ tool: 'list_tasks', arguments: { query: 'tea' } },
      { tool: 'inventory_search', arguments: { query: 'tea' } },
      { text: "<tool_call>\n<function=inventory_search>\n<parameter=query>\n</parameter>" })
    reply = ask('@rupert is there a tea shelf task and is tea low on stock?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'done', reply.reload.status
    assert_includes reply.body, 'I could not complete my answer'
    assert_includes reply.body, 'Task lookup (query: tea)'
    assert_includes reply.body, 'Recount tea shelf'
    assert_includes reply.body, 'availability is unknown'
    assert_not_includes reply.body, '<tool_call>'
    assert_not_includes reply.body, '<function='
  end

  test 'malformed tool markup without usable lookups asks for another try' do
    script_model({ text: '<tool_call><function=unknown>' })
    reply = ask('@rupert help me check this')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'I could not complete my answer. Please try again.', reply.reload.body
  end

  test 'an alert lookup tells the model that an empty list is not inventory coverage' do
    requests = script_model({ tool: 'list_alerts', arguments: {} }, { text: 'No open alerts were returned.' })
    reply = ask('@rupert are there low-stock alerts?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    tool_message = requests.last['messages'].find { |message| message['role'] == 'tool' }
    assert_includes tool_message['content'], 'no matching alerts do not prove stock is sufficient'
  end

  test 'alert-only answer does not present alert quantities as current inventory' do
    StockAlert.create!(sku: 'SYN-TEA', quantity: 0, threshold: 5, status: 'open')
    script_model({ tool: 'list_alerts', arguments: {} }, { text: 'SYN-TEA is out of stock right now.' })
    reply = ask('@rupert list the open low-stock alerts')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'SYN-TEA'
    assert_includes reply.body, 'alert quantity 0, threshold 5'
    assert_includes reply.body, 'may be stale'
    assert_not_includes reply.body, 'out of stock right now'
  end

  test 'financial answers also preserve alert scope and values' do
    StockAlert.create!(sku: 'SYN-TEA', quantity: 2, threshold: 5, status: 'open')
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'yesterday', compare: 'none' } },
      { tool: 'list_alerts', arguments: {} }, { text: 'Everything is in stock.' })
    reply = ask('@rupert what were sales yesterday and what alerts are open?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'SYN-TEA'
    assert_includes reply.body, 'alert quantity 2, threshold 5'
    assert_includes reply.body, 'not a current inventory check'
    assert_not_includes reply.body, 'Everything is in stock'
  end

  test 'task and alert lookups do not claim an alert is current stock' do
    StockAlert.create!(sku: 'SYN-TEA', quantity: 2, threshold: 5, status: 'open')
    script_model({ tool: 'list_tasks', arguments: { overdue: true, topic: 'stock' } },
      { tool: 'list_alerts', arguments: {} }, { text: 'SYN-TEA is still below its threshold with 2 on hand.' })
    reply = ask('@rupert Are there overdue stock tasks and is that stock still low?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Task lookup'
    assert_includes reply.body, 'alert quantity 2, threshold 5'
    assert_includes reply.body, 'Current stock levels could not be verified from alert records alone'
    assert_not_includes reply.body, '2 on hand'
  end

  test 'an alert table cannot make the answer claim its recorded quantity is current stock' do
    StockAlert.create!(sku: 'SYN-TEA', quantity: 2, threshold: 5, status: 'open')
    script_model({ tool: 'list_alerts', arguments: {} },
      { tool: 'show_view', arguments: { title: 'Alerts', kind: 'table', columns: %w[SKU Quantity], rows: [['SYN-TEA', 2]] } },
      { text: 'SYN-TEA currently has 2 on hand.' })
    reply = ask('@rupert Put today\'s open stock alerts in a side-panel table.')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'alert quantity 2, threshold 5'
    assert_includes reply.body, 'may be stale'
    assert_not_includes reply.body, '2 on hand'
    assert_equal 'table', reply.meta.fetch('views').sole['kind']
  end

  test 'a source sales chart cannot swap valid numbers between sources' do
    period = Metrics::Window.resolve(period: 'last_week')
    dates = { from: period.from.iso8601, to: period.to.iso8601 }
    data = { metric: 'sales_by_source', period: dates, source: nil, values: [
      { currency: 'USD', gross_cents: 11_200, sources: [
        { source: 'shopify', gross_cents: 7200, share_percent: 64.3 },
        { source: 'rupert_pos', gross_cents: 4000, share_percent: 35.7 }
      ] }
    ] }
    Mcp::Tools::Metric.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'sales by source', data: data))
    title = "Gross sales #{dates[:from]} to #{dates[:to]}"
    script_model({ tool: 'metric', arguments: { name: 'sales_by_source', period: 'last_week', compare: 'none' } },
      { tool: 'show_view', id: 'wrong', arguments: { title: title, kind: 'bar_chart', columns: ['Source', 'Gross sales USD'], rows: [['Shopify', 40], ['Rupert POS', 72]] } },
      { tool: 'show_view', id: 'correct', arguments: { title: title, kind: 'bar_chart', columns: ['Source', 'Gross sales USD'], rows: [['Shopify', 72], ['Rupert POS', 40]] } },
      { text: 'Here is the chart.' })
    reply = ask('@rupert Chart gross sales by source last week.')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entries = TeamChat::Run.find_by!(message_id: reply.id).tool_results
    assert_includes entries[1]['result'], 'could not be verified for its source'
    assert_equal [['Shopify', 72], ['Rupert POS', 40]], reply.reload.meta.fetch('views').sole['rows']
  end

  test 'cash flow cannot be inferred from sales but navigation remains available' do
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'this_month', compare: 'none' } },
      { text: 'Cash flow is positive because sales were strong.' })
    reply = ask('@rupert Is our cash flow positive this month?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'could not verify cash flow'
    assert_includes reply.body, 'sales or expenses alone do not establish cash in and out'
    assert_not_includes reply.body, 'cash flow is positive'

    script_model({ tool: 'where_is', arguments: { query: 'cash flow' } }, { text: 'Open the cash flow page.' })
    reply = ask('@rupert Where is the cash flow page?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_not_includes reply.reload.body, 'could not verify cash flow'
  end

  test 'timekeeping tool delivers worked hours even when sales are unavailable' do
    today = Date.current.iso8601
    requests = script_model({ tool: 'time_keeping_report', arguments: { from: today, to: today } }, { text: 'I checked timekeeping.' })
    reply = ask('@rupert how many hours did I work today? Explain the result.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal 'done', reply.reload.status
    assert_includes requests.last['messages'].find { |message| message['role'] == 'tool' }['content'], '"timekeeping"'
    assert_includes reply.body, 'hours worked'
  end

  test 'daily sales requested through the tool remain in the final answer' do
    yesterday = (Date.current - 1).iso8601
    today = Date.current.iso8601
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-daily-series', occurred_at: 1.day.ago.change(hour: 12),
      gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'sales_summary', arguments: { from: yesterday, to: today } },
      { text: 'Here are the sales.' })
    reply = ask('@rupert show daily sales for yesterday and today')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, "#{yesterday}: 214.83 USD gross"
    assert_includes reply.body, "#{today} (USD): no paid or fulfilled orders stored"
    assert_includes reply.body, 'Missing stored orders do not prove there were no sales'
    run = TeamChat::Run.find_by!(message_id: reply.id)
    assert_equal true, run.tool_results.find { |entry| entry['name'] == 'sales_summary' }['arguments']['include_daily']
  end

  test 'daily-series completion respects an explicit request to omit the breakdown' do
    today = Date.current.iso8601
    script_model({ tool: 'sales_summary', arguments: { from: today, to: today } }, { text: 'Here is the total.' })
    reply = ask('@rupert give me daily sales without a daily breakdown')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    run = TeamChat::Run.find_by!(message_id: reply.id)
    args = run.tool_results.find { |entry| entry['name'] == 'sales_summary' }['arguments']
    assert_not args.key?('include_daily')
  end

  test 'source-specific tax completes a missing metric filter and retains the original request' do
    script_model({ tool: 'metric', arguments: { name: 'tax_collected', period: 'last_month' } }, { text: 'Here is the recorded tax.' })
    reply = ask('@rupert tax collected on Shopify orders last month')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    result = TeamChat::Run.find_by!(message_id: reply.id).tool_results.find { |entry| entry['name'] == 'metric' }
    assert_equal 'shopify', result.dig('arguments', 'source')
    assert_not result.fetch('original_arguments').key?('source')
    assert_not_includes reply.reload.body, 'square canonical orders'
  end

  test 'tax source completion leaves comparisons, exclusions and explicit filters alone' do
    cases = [
      ['@rupert compare tax on Shopify orders with Square sales', { name: 'tax_collected' }],
      ['@rupert tax on Shopify orders excluding Shopify', { name: 'tax_collected' }],
      ['@rupert tax on Shopify orders', { name: 'tax_collected', source: 'square' }]
    ]
    cases.each do |question, arguments|
      script_model({ tool: 'metric', arguments: arguments }, { text: 'Here is the recorded tax.' })
      reply = ask(question)
      TeamChat::Agent.new(reply, config: team_chat_config).run
      result = TeamChat::Run.find_by!(message_id: reply.id).tool_results.find { |entry| entry['name'] == 'metric' }
      assert_equal arguments.stringify_keys, result['arguments']
    end
  end

  test 'single-day order comparison corrects metric and period while retaining original arguments' do
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'last_year' } }, { text: 'Here is the comparison.' })
    reply = ask('@rupert orders today vs same day last year')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    result = TeamChat::Run.find_by!(message_id: reply.id).tool_results.find { |entry| entry['name'] == 'metric' }
    assert_equal({ 'name' => 'orders', 'period' => 'today', 'compare' => 'last_year' }, result['arguments'])
    assert_equal({ 'name' => 'gross_sales', 'period' => 'last_year' }, result['original_arguments'])
    assert_includes reply.reload.body, 'No metric rows were returned for the requested period'
    assert_includes reply.body, 'No metric rows were returned for the comparison period'
  end

  test 'order comparison correction leaves mixed or excluded questions alone' do
    ['@rupert sales and orders today vs same day last year', '@rupert orders today without comparing the same day last year'].each do |question|
      original = { name: 'gross_sales', period: 'today' }
      script_model({ tool: 'metric', arguments: original }, { text: 'Here are the results.' })
      reply = ask(question)
      TeamChat::Agent.new(reply, config: team_chat_config).run
      result = TeamChat::Run.find_by!(message_id: reply.id).tool_results.find { |entry| entry['name'] == 'metric' }
      assert_equal original.stringify_keys, result['arguments']
    end
  end

  test 'empty open purchase order lookup survives the financial guard' do
    data = { view: 'orders', rows: [], meta: { has_more: false }, totals: [{ placed_total_cents: 0 }] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'No purchase orders', data: data))
    script_model({ tool: 'purchase_orders', arguments: { status: 'open' } }, { text: 'There are orders waiting.' })
    reply = ask('@rupert which purchase orders are open?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Purchase orders (status: open)'
    assert_includes reply.body, 'No purchase orders were returned on this page'
    assert_not_includes reply.body, 'There are orders waiting'
  end

  test 'vendor lookup keeps purchase-order values separate from recorded payments' do
    today = Date.current.iso8601
    data = { view: 'vendors', from: today, to: today, currency: 'USD', meta: { has_more: false },
             rows: [{ name: 'Tea supplier', spend_cents: 1200, paid_in_window_cents: 500 }] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'one vendor', data: data))
    script_model({ tool: 'purchase_orders', arguments: { view: 'vendors', from: today, to: today } }, { text: 'Payments were $12.00.' })
    reply = ask('@rupert what did we order and pay this vendor today?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'placed PO value, not payments: 12.00 USD'
    assert_includes reply.body, 'recorded vendor payments in the period: 5.00 USD'
    assert_not_includes reply.body, 'Payments were $12.00'
  end

  test 'a named vendor payments question corrects a vendor name sent as an order query' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    today = Date.current.iso8601
    first = Date.current.beginning_of_month.iso8601
    data = { view: 'vendors', from: first, to: today, currency: 'USD', meta: { has_more: false },
             rows: [{ name: vendor.name, spend_cents: 1200, paid_in_window_cents: 500 }] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'one vendor', data: data))
    script_model({ tool: 'purchase_orders', arguments: { query: vendor.name } }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what was the PO value and vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'placed PO value, not payments: 12.00 USD'
    assert_includes reply.body, 'recorded vendor payments in the period: 5.00 USD'
    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal({ 'view' => 'vendors', 'vendor' => vendor.name, 'vendor_exact' => true, 'from' => first, 'to' => today }, args)
  end

  test 'a named vendor value question corrects an empty order query' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    first = Date.current.beginning_of_month.iso8601
    today = Date.current.iso8601
    data = { view: 'vendors', from: first, to: today, currency: 'USD', meta: { has_more: false },
             rows: [{ name: vendor.name, spend_cents: 1200, paid_in_window_cents: 500 }] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'one vendor', data: data))
    script_model({ tool: 'purchase_orders', arguments: { view: 'orders', query: '', from: first, to: today } }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what was the PO value and vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'recorded vendor payments in the period: 5.00 USD'
    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal({ 'view' => 'vendors', 'vendor' => vendor.name, 'vendor_exact' => true, 'from' => first, 'to' => today }, args)
  end

  test 'a named vendor value question corrects an unfiltered all-status order lookup' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    first = Date.current.beginning_of_month.iso8601
    today = Date.current.iso8601
    data = { view: 'vendors', from: first, to: today, currency: 'USD', meta: { has_more: false }, rows: [] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no vendors', data: data))
    script_model({ tool: 'purchase_orders', arguments: { view: 'orders', status: 'all', from: first, to: today } }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what was the PO value and vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal({ 'view' => 'vendors', 'vendor' => vendor.name, 'vendor_exact' => true, 'from' => first, 'to' => today }, args)
  end

  test 'a named vendor payment question makes an implicit vendor filter exact' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    first = Date.current.beginning_of_month.iso8601
    today = Date.current.iso8601
    data = { view: 'vendors', from: first, to: today, currency: 'USD', meta: { has_more: false }, rows: [] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no vendors', data: data))
    original = { view: 'vendors', vendor: vendor.name, from: first, to: today }
    script_model({ tool: 'purchase_orders', arguments: original }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what was the PO value and vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal original.stringify_keys.merge('vendor_exact' => true), args
  end

  test 'supplemental order lookup keeps its requested filters and exact vendor' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    first = Date.current.beginning_of_month.iso8601
    today = Date.current.iso8601
    data = { view: 'orders', meta: { has_more: false }, rows: [] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no orders', data: data))
    original = { vendor: vendor.name, status: 'all', include_lines: false, from: first, to: today }
    script_model({ tool: 'purchase_orders', arguments: original }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what was the PO value and vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal original.stringify_keys.merge('vendor_exact' => true), args
  end

  test 'a request for matching vendor names retains substring matching' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    data = { view: 'orders', meta: { has_more: false }, rows: [] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no orders', data: data))
    original = { vendor: vendor.name, status: 'all', include_lines: false }
    script_model({ tool: 'purchase_orders', arguments: original }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, show total vendor payments for matching names.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal original.stringify_keys, args
  end

  test 'vendor payment correction does not override a request for order line items' do
    Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    data = { view: 'orders', rows: [], meta: { has_more: false } }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no orders', data: data))
    original = { view: 'orders', query: '' }
    script_model({ tool: 'purchase_orders', arguments: original }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, show line items and total vendor payments.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal original.stringify_keys, args
  end

  test 'a partial vendor-name query is not silently changed to a different vendor' do
    Purchasing::Vendor.create!(name: 'Synthetic Tea')
    data = { view: 'orders', rows: [], meta: { has_more: false } }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no orders', data: data))
    script_model({ tool: 'purchase_orders', arguments: { query: 'Synthetic Tea' } }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what were the vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal({ 'query' => 'Synthetic Tea' }, args)
  end

  test 'a case-insensitive vendor-name collision is not automatically resolved' do
    Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    Purchasing::Vendor.create!(name: 'SYNTHETIC TEA SUPPLY')
    data = { view: 'orders', rows: [], meta: { has_more: false } }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no orders', data: data))
    script_model({ tool: 'purchase_orders', arguments: { query: 'Synthetic Tea Supply' } }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply this month, what were the vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal({ 'query' => 'Synthetic Tea Supply' }, args)
  end

  test 'vendor-payment correction preserves an explicitly requested previous month' do
    vendor = Purchasing::Vendor.create!(name: 'Synthetic Tea Supply')
    preset = TimeRangePicker.preset('last_month', Date.current)
    from = preset.from.iso8601
    to = preset.to.iso8601
    data = { view: 'vendors', from: from, to: to, currency: 'USD', meta: { has_more: false }, rows: [] }
    Mcp::Tools::PurchaseOrders.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'no vendors', data: data))
    script_model({ tool: 'purchase_orders', arguments: { query: vendor.name } }, { text: 'I checked.' })
    reply = ask('@rupert For Synthetic Tea Supply last month, what were the vendor payments?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    args = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first['arguments']
    assert_equal [from, to, true], args.values_at('from', 'to', 'vendor_exact')
  end

  test 'order queues with financial fields retain their operational counts' do
    data = { queues: [{ name: 'Paid online orders not shipped', count: 1, late: 0 }], low_stock_available: false,
             oldest_unshipped: [{ order: 'A-1', source: 'shopify', gross_cents: 1234, lines: [] }] }
    Mcp::Tools::OrderQueues.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'one waiting', data: data))
    script_model({ tool: 'order_queues', arguments: {} }, { text: 'Nothing is waiting.' })
    reply = ask('@rupert what orders are waiting to ship?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Paid online orders not shipped: 1'
    assert_includes reply.body, 'Low-stock alert matching was unavailable'
    assert_not_includes reply.body, 'Nothing is waiting'
  end

  test 'late or awaiting delivery purchase orders use the scoped queue counts' do
    data = { queues: [{ name: 'Purchase orders awaiting delivery', count: 3, late: 1 }], low_stock_available: false, oldest_unshipped: [] }
    Mcp::Tools::OrderQueues.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'waiting', data: data))
    script_model({ tool: 'order_queues', arguments: {} }, { text: 'I checked.' })
    reply = ask('@rupert Are any purchase orders late or still waiting for delivery?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'Purchase orders awaiting delivery: 3; 1 late'
    assert_not_includes reply.body, 'Paid online orders not shipped'
  end

  test 'an explicit order count does not add the metric default comparison' do
    script_model({ tool: 'metric', arguments: { name: 'orders', period: 'yesterday' } }, { text: 'I checked.' })
    reply = ask('@rupert How many orders were recorded yesterday?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal 'none', entry.dig('arguments', 'compare')
    assert_not entry.fetch('original_arguments').key?('compare')

    script_model({ tool: 'metric', arguments: { name: 'orders', period: 'yesterday', compare: 'previous' } }, { text: 'I checked.' })
    reply = ask('@rupert How many orders were recorded yesterday?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal 'previous', entry.dig('arguments', 'compare')

    script_model({ tool: 'metric', arguments: { name: 'orders', period: 'yesterday' } }, { text: 'I checked.' })
    reply = ask('@rupert How many orders were recorded yesterday compared with the previous day?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_not entry.fetch('arguments').key?('compare')
  end

  test 'sales day direction follows an unambiguous question without changing filters' do
    script_model({ tool: 'metric', arguments: { name: 'best_day', period: 'last_month', source: 'square', compare: 'none' } }, { text: 'I checked.' })
    reply = ask('@rupert What was the slowest sales day last month?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal 'best_day', entry.dig('original_arguments', 'name')
    assert_equal ['worst_day', 'last_month', 'square', 'none'], entry.fetch('arguments').values_at('name', 'period', 'source', 'compare')

    script_model({ tool: 'metric', arguments: { name: 'best_day', period: 'last_month', compare: 'none' } }, { text: 'I checked.' })
    reply = ask('@rupert Compare the best and slowest sales day last month.')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'best_day', TeamChat::Run.find_by!(message_id: reply.id).tool_results.first.dig('arguments', 'name')

    script_model({ tool: 'metric', arguments: { name: 'worst_day', period: 'last_week', compare: 'none' } }, { text: 'I checked.' })
    reply = ask('@rupert What was the busiest sales day last week?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'best_day', TeamChat::Run.find_by!(message_id: reply.id).tool_results.first.dig('arguments', 'name')

    script_model({ tool: 'metric', arguments: { name: 'worst_day', period: 'last_week', compare: 'none' } }, { text: 'I checked.' })
    reply = ask('@rupert Which day of the week has the best sales?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal 'worst_day', TeamChat::Run.find_by!(message_id: reply.id).tool_results.first.dig('arguments', 'name')
  end

  test 'a total by source request asks for both the total and source data' do
    date = Date.current.prev_month.beginning_of_month
    order = Core::Order.create!(source: 'square', source_order_id: 'source-breakdown', occurred_at: date.to_time.change(hour: 12),
      gross_cents: 8_000, tax_cents: 0, currency: 'USD')
    order.mark_paid!
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'last_month' } }, { text: 'I checked.' })
    reply = ask('@rupert What were total gross sales last month, by source?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal 'gross_sales', entry.dig('original_arguments', 'name')
    assert_equal 'sales_by_source', entry.dig('arguments', 'name')
    assert_equal 'none', entry.dig('arguments', 'compare')
    assert_includes reply.reload.body, 'Gross sales total (paid or fulfilled orders): 80.00 USD'
    assert_includes reply.body, 'square canonical orders'

    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'last_month', compare: 'previous' } }, { text: 'I checked.' })
    reply = ask('@rupert What were total gross sales last month, by source, and compare with the previous month?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal 'gross_sales', entry.dig('arguments', 'name')
    assert_equal 'previous', entry.dig('arguments', 'compare')

    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'last_month', source: 'square' } }, { text: 'I checked.' })
    reply = ask('@rupert What were total gross sales last month, by source?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
    assert_equal 'gross_sales', entry.dig('arguments', 'name')
    assert_equal 'square', entry.dig('arguments', 'source')
  end

  test 'a narrow queue answer omits unrelated results while a mixed question keeps them' do
    data = { queues: [{ name: 'Expense receipts waiting for review', count: 0 },
                      { name: 'Purchase orders awaiting delivery', count: 1, late: 0 },
                      { name: 'Paid online orders not shipped', count: 9 }], low_stock_available: false, oldest_unshipped: [] }
    Mcp::Tools::OrderQueues.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'queue counts', data: data))
    compliance = { items: [{ title: 'Books closed', area: 'Books', status: 'watch', detail: 'Review needed' }] }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: compliance))
    script_model({ tool: 'order_queues', arguments: {} }, { tool: 'compliance_check', arguments: {} }, { text: 'I checked.' })
    reply = ask('@rupert What receipts need review and are any purchase orders late?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'Expense receipts waiting for review: 0'
    assert_includes reply.body, 'Purchase orders awaiting delivery: 1; 0 late'
    assert_not_includes reply.body, 'Paid online orders not shipped'
    assert_not_includes reply.body, 'Books closed'

    script_model({ tool: 'order_queues', arguments: {} }, { tool: 'compliance_check', arguments: {} }, { text: 'I checked.' })
    reply = ask('@rupert What receipts need review and are the books closed?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'Paid online orders not shipped: 9'
    assert_includes reply.body, 'Books closed'
  end

  test 'refunded order questions use the scoped count rather than paid order totals' do
    data = { from: (Date.current - 29).iso8601, to: Date.current.iso8601,
             lines: [], totals_by_currency: [], refunded_orders_by_source: { 'shopify' => 2 } }
    Mcp::Tools::SalesSummary.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'sales', data: data))
    script_model({ tool: 'sales_summary', arguments: {} }, { text: 'No refunds occurred.' })
    reply = ask('@rupert How many orders were refunded in the last 30 days, and from which sources?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_includes reply.reload.body, 'shopify: 2 orders'
    assert_includes reply.body, 'order date and current order status'
    assert_not_includes reply.body, 'No refunds occurred'

    script_model({ text: 'No refunds occurred.' })
    reply = ask('@rupert How many orders were refunded in the last 30 days?')
    TeamChat::Agent.new(reply, config: team_chat_config).run
    assert_equal TeamChat::Agent::UNCHECKED_RECORDS, reply.reload.body
  end

  test 'a failed source chart can fall back to verified recorded source figures' do
    travel_to Time.zone.parse('2026-10-27 12:00') do
      args = { from: '2026-10-19', to: '2026-10-25' }
      data = args.merge(lines: [{ source: 'shopify', currency: 'USD', orders: 1, gross_cents: 7200, tax_cents: 0 },
                                { source: 'rupert_pos', currency: 'USD', orders: 1, gross_cents: 4000, tax_cents: 0 }],
        totals_by_currency: [], refunded_orders_by_source: {})
      Mcp::Tools::SalesSummary.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'sales', data: data))
      script_model({ tool: 'sales_summary', arguments: args }, { text: 'I checked the sales.' })
      reply = ask("@rupert Show a chart of last week's gross sales by source")
      TeamChat::Agent.new(reply, config: team_chat_config).run
      view = reply.reload.meta.fetch('views').first
      assert_equal 'bar_chart', view['kind']
      assert_equal [['rupert_pos', '40.0'], ['shopify', '72.0']], view['rows']
      assert_includes view['note'], 'Missing records do not prove zero'
    end
  end

  test 'a sales trend requests daily evidence and can show a verified adjustable chart' do
    travel_to Time.zone.parse('2026-10-27 12:00') do
      args = { from: '2026-10-19', to: '2026-10-25' }
      data = args.merge(lines: [], totals_by_currency: [], refunded_orders_by_source: {}, daily: [
        { date: '2026-10-19', currency: 'USD', orders: 1, gross_cents: 4000 },
        { date: '2026-10-20', currency: 'USD', orders: 0, gross_cents: 0 }
      ])
      (21..25).each { |day| data[:daily] << { date: "2026-10-#{day}", currency: 'USD', orders: 0, gross_cents: 0 } }
      Mcp::Tools::SalesSummary.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'sales', data: data))
      script_model({ tool: 'sales_summary', arguments: args }, { text: 'I checked the sales.' })
      reply = ask("@rupert Plot last week's recorded sales trend")
      TeamChat::Agent.new(reply, config: team_chat_config).run
      entry = TeamChat::Run.find_by!(message_id: reply.id).tool_results.first
      assert_equal true, entry.dig('arguments', 'include_daily')
      view = reply.reload.meta.fetch('views').first
      assert_equal 'line_chart', view['kind']
      assert_equal [['2026-10-19', '40.0'], ['2026-10-20', nil]], view['rows'].first(2)
    end
  end

  test 'a nonempty receipt count does not replace a request for receipt identities' do
    data = { queues: [{ name: 'Expense receipts waiting for review', count: 2 }],
             low_stock_available: false, oldest_unshipped: [] }
    compliance = { items: [{ title: 'Books closed', area: 'Books', status: 'watch', detail: 'Review needed' }] }
    Mcp::Tools::OrderQueues.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'queue counts', data: data))
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'compliance', data: compliance))
    script_model({ tool: 'order_queues', arguments: {} }, { tool: 'compliance_check', arguments: {} }, { text: 'I checked.' })
    reply = ask('@rupert Which expense receipts require review?')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Expense receipts waiting for review: 2'
    assert_includes reply.body, 'Books closed'
    assert_not_includes reply.body, 'counts, not individual receipt'
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

  test 'malformed tool markup cannot pass financial prose verification' do
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-malformed', occurred_at: Time.current, gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } },
      { text: 'Gross sales today were $214.83. <tool_call><function=metric>' })
    reply = ask('@rupert show gross sales today')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, '214.83 USD'
    assert_not_includes reply.body, '<tool_call>'
    assert_equal false, reply.meta['prose_checked']
  end

  test 'financial verification retains separate inventory observations' do
    product = ShopifyProduct.create!(id: 'chat-product', title: 'Tea')
    variant = ShopifyVariant.create!(id: 'chat-variant', productId: product.id, sku: 'CHAT-TEA', title: '50g')
    location = Location.create!(id: 'chat-location', source: 'shopify', externalId: 'chat-external', name: 'Tea shelf')
    InventoryLevel.create!(id: 'chat-level', source: 'shopify', locationId: location.id, shopifyVariantId: variant.id, quantity: 12, available: 9)
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-order', occurred_at: Time.current, gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } },
      { tool: 'inventory_search', arguments: { query: 'CHAT-TEA' } }, { text: 'Sales were $214.83 and tea has 999 available.' })
    reply = ask('@rupert show sales today and tea stock')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, '214.83 USD'
    assert_includes reply.body, 'Tea shelf (shopify): 9 available'
    assert_not_includes reply.body, '999 available'
    assert_equal false, reply.meta['prose_checked']
  end

  test 'empty inventory lookup cannot be turned into a stock all-clear' do
    script_model({ tool: 'list_tasks', arguments: { query: 'tea' } },
      { tool: 'inventory_search', arguments: { query: 'tea' } }, { text: 'Everything is in stock.' })
    reply = ask('@rupert are there tea tasks and is tea stock low?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Task lookup (query: tea)'
    assert_includes reply.body, 'availability is unknown'
    assert_not_includes reply.body, 'Everything is in stock'
  end

  test 'financial verification retains task lookup results' do
    Projects::Task.create!(title: 'Recount tea shelf', priority: 'high')
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-task-order', occurred_at: Time.current, gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } },
      { tool: 'list_tasks', arguments: { query: 'tea' } }, { text: 'Sales were $214.83, and tea has no task.' })
    reply = ask('@rupert show sales today and tea tasks')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, '214.83 USD'
    assert_includes reply.body, 'Task lookup (query: tea)'
    assert_includes reply.body, 'Recount tea shelf'
    assert_not_includes reply.body, 'tea has no task'
  end

  test 'financial verification retains the compliance check' do
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-compliance-order', occurred_at: Time.current, gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'compliance_check', arguments: {} },
      { tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } },
      { text: 'Sales were $214.83 and nothing needs review.' })
    reply = ask('@rupert show sales and books blockers')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, '214.83 USD'
    assert_includes reply.body, 'Compliance check:'
    assert_not_includes reply.body, 'nothing needs review'
  end

  test 'long compliance lookup remains usable beside financial evidence' do
    items = 30.times.map { |i| { title: "Close item #{i}", area: 'Books', status: 'watch', detail: 'review required' } }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'many items', data: { items: items }))
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-long-compliance', occurred_at: Time.current, gross_cents: 100, currency: 'USD').mark_paid!
    script_model({ tool: 'compliance_check', arguments: {} },
      { tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } },
      { text: 'No blockers.' })
    reply = ask('@rupert show sales and books blockers')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Close item 0'
    assert_includes reply.body, 'Additional compliance items were omitted'
    result = TeamChat::Run.find_by!(message_id: reply.id).tool_results.find { |entry| entry['name'] == 'compliance_check' }
    assert_operator result['result'].length, :<, TeamChat::Toolbox::MAX_RESULT_CHARS
    assert JSON.parse(result['result'].partition("\n").last)['omitted']
  end

  test 'compliance-only answers retain status and omissions instead of model claims' do
    items = 25.times.map { |i| { title: "Close item #{i}", area: 'Books', status: 'watch', detail: 'review required' } }
    Mcp::Tools::ComplianceCheck.any_instance.stubs(:call).returns(Mcp::Result.new(text: 'many items', data: { items: items }))
    script_model({ tool: 'compliance_check', arguments: {} }, { text: 'Everything is complete and nothing was omitted.' })
    reply = ask('@rupert what books checks need attention?')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Close item 0 (Books; watch)'
    assert_includes reply.body, 'Additional compliance items were omitted'
    assert_not_includes reply.body, 'Everything is complete'
  end

  test 'unchecked compliance and uncertain inventory prose are not streamed as answers' do
    agent = TeamChat::Agent.allocate
    execution = mock('execution')
    execution.expects(:write_reply!).never
    agent.instance_variable_set(:@execution, execution)

    toolbox = stub('toolbox', financial?: false, tools_used: ['compliance_check'], inventory_results: [])
    agent.instance_variable_set(:@toolbox, toolbox)
    agent.send(:publish, 'Everything is complete.')

    toolbox = stub('toolbox', financial?: false, tools_used: ['inventory_search'],
      inventory_results: ["result\n#{JSON.generate(rows: [], meta: {})}"])
    agent.instance_variable_set(:@toolbox, toolbox)
    agent.send(:publish, 'Everything is in stock.')
  end

  test 'business pulse keeps operational sections in the final answer' do
    script_model({ tool: 'business_pulse', arguments: {} }, { text: 'Nothing is waiting.' })
    reply = ask('@rupert give me a business health check today')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, 'Business pulse for'
    assert_includes reply.body, 'Open alerts:'
    assert_match(/waiting queues/i, reply.body)
    assert_not_includes reply.body, 'Nothing is waiting.'
  end

  test 'financial verification retains source sync health' do
    Core::Order.create!(source: 'shopify', source_order_id: 'chat-sync-order', occurred_at: Time.current, gross_cents: 21483, currency: 'USD').mark_paid!
    script_model({ tool: 'metric', arguments: { name: 'gross_sales', period: 'today', source: 'shopify', compare: 'none' } },
      { tool: 'sync_health', arguments: {} }, { text: 'Sales were $214.83 and sync is perfect.' })
    reply = ask('@rupert show sales and whether the source is syncing')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, '214.83 USD'
    assert_includes reply.body, 'Source sync health:'
    assert_includes reply.body, 'does not establish complete sales coverage'
    assert_not_includes reply.body, 'sync is perfect'
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

  test 'a figure from the question is not marked as verified by an unrelated tool' do
    script_model({ tool: 'where_is', arguments: { query: 'timesheets' } }, { text: 'You mentioned 37 hours. Timesheets are under Team.' })
    reply = ask('@rupert where are timesheets? I mentioned 37 hours.')
    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_includes reply.reload.body, '37 hours'
    assert_not reply.as_payload(viewer: @user)[:figures_checked]
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

  test 'explicitly excluded task and feedback proposals are denied' do
    script_model({ tool: 'create_task', arguments: { title: 'Courier arrives at four' } },
      { tool: 'submit_feedback', arguments: { kind: 'suggestion', summary: 'Courier note' } },
      { text: 'I could not save a standalone note.' })
    reply = ask('@rupert Make a note that the courier comes at 4, without creating a task or sending feedback.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_empty reply.reload.actions_list
    results = TeamChat::Run.find_by!(message_id: reply.id).tool_results
    assert_equal %w[create_task submit_feedback], results.pluck('name')
    assert results.all? { |entry| entry['result'].include?('explicitly excluded') }
  end

  test 'a separate allowed feedback request is not blocked by a task exclusion' do
    script_model({ tool: 'create_task', arguments: { title: 'Courier arrives at four' } },
      { tool: 'submit_feedback', arguments: { kind: 'suggestion', summary: 'Courier note' } },
      { text: 'The feedback proposal is waiting for approval.' })
    reply = ask('@rupert Do not create a task, but send feedback about the courier note.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal ['submit_feedback'], reply.reload.actions_list.pluck('tool')
    results = TeamChat::Run.find_by!(message_id: reply.id).tool_results
    assert_includes results.first['result'], 'explicitly excluded'
  end

  test 'a quoted task title is not treated as an instruction to exclude the task' do
    script_model({ tool: 'create_task', arguments: { title: 'Do not create a task' } },
      { text: 'The task proposal is waiting for approval.' })
    reply = ask('@rupert Create a task titled “Do not create a task”.')

    TeamChat::Agent.new(reply, config: team_chat_config).run

    assert_equal ['create_task'], reply.reload.actions_list.pluck('tool')
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
