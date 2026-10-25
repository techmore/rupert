# frozen_string_literal: true

require 'test_helper'

# The nine read-only tools added with the question bank (issue #404): each one
# answers only from the asking person's workspace and only with their permissions.
class NewToolsIsolationTest < ActiveSupport::TestCase
  MARK = 'OTHERTENANT'
  TOOLS = {
    Mcp::Tools::CustomerLookup => ['customers:read', 'customers.read'],
    Mcp::Tools::CustomerInsights => ['customers:read', 'customers.read'],
    Mcp::Tools::MarketingRecords => ['marketing:read', 'marketing.read'],
    Mcp::Tools::MarketingSummary => ['marketing:read', 'marketing.read'],
    Mcp::Tools::ListProjects => ['tasks:read', 'projects.read'],
    Mcp::Tools::StaffSchedule => ['timesheets:read', 'timesheets.read'],
    Mcp::Tools::ActivityLog => ['system:read', 'system.read'],
    Mcp::Tools::PurchaseOrders => ['purchasing:read', 'purchasing.read'],
    Mcp::Tools::StockMovements => ['inventory:read', 'inventory.read']
  }.freeze

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @other = Tenant.create!(name: 'Other workspace', subdomain: 'other-new-tools')
    seed_other_workspace
    Current.tenant = @tenant
    Current.user = @user
    @token = TeamChat::Token.new(@user)
  end

  teardown { Current.reset }

  def seed_other_workspace
    Current.tenant = @other
    stranger = User.create!(tenant: @other, email: 'stranger@example.invalid', password: 'password123', role: 'admin', name: "#{MARK} Stranger")
    Current.user = stranger
    customer = Core::Customer.create!(source: 'manual', external_id: 'manual:other', first_name: MARK, last_name: 'Buyer', crm_status: 'vip', tags: MARK)
    order = Core::Order.create!(source: 'shopify', source_order_id: 'other-1', order_number: '#77001', occurred_at: 2.days.ago,
      gross_cents: 9900, tax_cents: 0, currency: 'USD', channel: 'online', customer: customer)
    order.mark_paid!
    order.order_lines.create!(name: "#{MARK} Tea", sku: 'OTHER-TEA', unit_cents: 9900, quantity: 1, line_cents: 9900)
    CustomerFollowUp.create!(customer: customer, author_id: stranger.id, owner_id: stranger.id, title: "#{MARK} call back", due_on: Date.current - 1)
    CustomerInteraction.create!(customer: customer, author_id: stranger.id, kind: 'call', body: "#{MARK} asked about tea")
    campaign = Marketing::Campaign.create!(name: "#{MARK} campaign", storefront_url: 'https://other.example.com', topics: MARK)
    Marketing::Community.create!(campaign: campaign, name: "#{MARK} group", url: 'https://www.reddit.com/r/othertenant',
      include_terms: 'tea', promotion_rules: 'Disclose affiliation.', rules_url: 'https://www.reddit.com/r/othertenant/about/rules', rules_checked_at: Time.current)
    Marketing::Influencer.create!(name: "#{MARK} creator", stage: 'interested', next_follow_up_at: 1.day.ago)
    goal = Goals::Goal.create!(name: "#{MARK} goal", target_value: 10, current_value: 1)
    @other_project = Projects::Project.create!(name: "#{MARK} project", goal: goal)
    Projects::Task.create!(title: "#{MARK} task", project: @other_project)
    employee = People::Employee.create!(first_name: MARK, last_name: 'Worker')
    People::ScheduledShift.create!(employee: employee, starts_at: Date.current.in_time_zone + 9.hours, ends_at: Date.current.in_time_zone + 17.hours)
    vendor = Purchasing::Vendor.create!(name: "#{MARK} Vendor")
    po = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: 'PO-OTHER-1')
    po.lines.create!(name: "#{MARK} bottle", sku: 'OTHER-BOTTLE', quantity: 5, unit_cost_cents: 100)
    ActivityLogger.log('po_placed', subject: po, actor: stranger, details: MARK)
    InventoryMovement.create!(sku: 'OTHER-TEA', source: 'square', direction: 'set', delta: -3, quantityBefore: 10, quantityAfter: 7,
      reason: MARK, actor: 'system', createdAt: 1.hour.ago)
    @other_customer = customer
  end

  def run_tool(klass, args = {}, token = @token)
    klass.new(token: token).call(args)
  rescue Mcp::ToolError => e
    e
  end

  # Search words the tool repeats back ("No customer name matches ...") are removed before checking.
  def assert_nothing_from_other(outcome, label, echoed = [])
    text = outcome.is_a?(Mcp::ToolError) ? outcome.message : "#{outcome.text} #{outcome.data.to_json}"
    echoed.each { |value| text = text.gsub(value.to_s, '') }
    assert_no_match(/#{MARK}|OTHER-TEA|OTHER-BOTTLE|PO-OTHER|77001/io, text, "#{label} returned another workspace's data")
  end

  test 'every new tool answers only from the asking workspace' do
    calls = [
      [Mcp::Tools::CustomerLookup, { 'query' => MARK }], [Mcp::Tools::CustomerLookup, { 'customer_id' => @other_customer.id }],
      [Mcp::Tools::CustomerLookup, { 'order_number' => '77001' }],
      *%w[top new repeat lapsed segments follow_ups interactions].map { |view| [Mcp::Tools::CustomerInsights, { 'view' => view, 'status' => (view == 'follow_ups' ? 'open' : nil), 'tag' => (view == 'segments' ? MARK : nil) }.compact] },
      *Mcp::Tools::MarketingRecords::KINDS.map { |kind| [Mcp::Tools::MarketingRecords, { 'kind' => kind }] },
      [Mcp::Tools::MarketingSummary, {}],
      [Mcp::Tools::ListProjects, { 'status' => 'all' }], [Mcp::Tools::ListProjects, { 'view' => 'goals', 'status' => 'all' }],
      [Mcp::Tools::ListProjects, { 'project_id' => @other_project.id }],
      [Mcp::Tools::StaffSchedule, {}], [Mcp::Tools::StaffSchedule, { 'view' => 'staff' }],
      [Mcp::Tools::ActivityLog, {}], [Mcp::Tools::ActivityLog, { 'query' => MARK }],
      [Mcp::Tools::PurchaseOrders, {}], [Mcp::Tools::PurchaseOrders, { 'query' => 'OTHER' }], [Mcp::Tools::PurchaseOrders, { 'view' => 'vendors' }],
      [Mcp::Tools::StockMovements, {}], [Mcp::Tools::StockMovements, { 'query' => 'OTHER-TEA' }], [Mcp::Tools::StockMovements, { 'ledger' => 'bulk' }]
    ]
    calls.each do |klass, args|
      echoed = args.slice('query', 'tag', 'order_number').values
      assert_nothing_from_other(run_tool(klass, args), "#{klass.tool_name} #{args.to_json}", echoed)
    end
    assert_kind_of Mcp::ToolError, run_tool(Mcp::Tools::CustomerLookup, { 'customer_id' => @other_customer.id })
    assert_kind_of Mcp::ToolError, run_tool(Mcp::Tools::ListProjects, { 'project_id' => @other_project.id })
  end

  test 'the same tools still see the other workspace from inside it' do
    Current.tenant = @other
    stranger = User.find_by!(email: 'stranger@example.invalid')
    token = TeamChat::Token.new(stranger)
    assert_match(/#{MARK}/o, run_tool(Mcp::Tools::CustomerLookup, { 'query' => MARK }, token).text)
    assert_match(/PO-OTHER-1/, run_tool(Mcp::Tools::PurchaseOrders, {}, token).text)
    assert_equal 1, run_tool(Mcp::Tools::StockMovements, {}, token).data[:total]
  end

  test 'each tool is refused without the matching permission' do
    TOOLS.each do |klass, (_scope, permission)|
      person = User.create!(tenant: @tenant, email: "no-#{klass.tool_name}@example.invalid", password: 'password123', role: 'admin')
      person.update_permission_overrides!(User::ROLE_PERMISSIONS.fetch('admin') - [permission])
      assert_not klass.available_to?(TeamChat::Token.new(person.reload)), "#{klass.tool_name} offered without #{permission}"
      assert klass.available_to?(@token), "#{klass.tool_name} should be offered to an admin"
    end
  end

  test 'activity_log also needs settings.read, like the Activity page' do
    person = User.create!(tenant: @tenant, email: 'system-only@example.invalid', password: 'password123', role: 'admin')
    person.update_permission_overrides!(%w[system.read])
    assert_not Mcp::Tools::ActivityLog.available_to?(TeamChat::Token.new(person.reload))
  end

  test 'staff_schedule shows only their own shifts to people who cannot open the Team schedule' do
    lead = User.create!(tenant: @tenant, email: 'lead@example.invalid', password: 'password123', role: 'shift_leader', name: 'Lee Lead')
    own = People::Employee.create!(first_name: 'Lee', last_name: 'Lead', user: lead)
    coworker = People::Employee.create!(first_name: 'Private', last_name: 'Coworker')
    [own, coworker].each do |employee|
      People::ScheduledShift.create!(employee: employee, starts_at: Date.current.in_time_zone + 9.hours, ends_at: Date.current.in_time_zone + 12.hours)
    end
    token = TeamChat::Token.new(lead)
    assert lead.can_review_timesheets?, 'shift leaders review timesheets but cannot open the Team schedule'
    data = run_tool(Mcp::Tools::StaffSchedule, {}, token).data
    assert_equal ['own shifts only', 1], [data[:scope], data[:totals][:shifts]]
    assert_no_match(/Private Coworker/, data.to_json)
  end

  test 'an API token without the scope is denied over MCP, even for an administrator' do
    token, = ApiAccessToken.issue(attributes: { name: 'Roadmap only', scopes: ['roadmap:read'] }, user: @user, tenant: @tenant)
    server = Mcp::Server.new(token: token)
    listed = server.handle({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' }).first.dig(:result, :tools).map { |tool| tool[:name] }
    TOOLS.each_key do |klass|
      assert_not_includes listed, klass.tool_name
      payload, = server.handle({ 'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call', 'params' => { 'name' => klass.tool_name, 'arguments' => {} } })
      assert payload.dig(:result, :isError), "#{klass.tool_name} answered a token without its scope"
      assert_match(/not allowed to use #{klass.tool_name}/, payload.dig(:result, :content, 0, :text))
    end
  end

  test 'the new tools are read-only and never offered as writes' do
    TOOLS.each_key do |klass|
      assert klass.read_only, "#{klass.tool_name} must be read-only"
      assert_not_includes ApiAccessToken::WRITE_SCOPES, klass.scope
    end
  end

  def queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    count
  end

  def add_rows(index)
    customer = Core::Customer.create!(source: 'manual', external_id: "manual:n#{index}", first_name: "Buyer#{index}", last_name: 'Here')
    order = Core::Order.create!(source: 'shopify', source_order_id: "n-#{index}", order_number: "#n#{index}", occurred_at: 1.day.ago,
      gross_cents: 1000 + index, tax_cents: 0, currency: 'USD', channel: 'online', customer: customer)
    order.mark_paid!
    project = Projects::Project.create!(name: "Project #{index}", owner_id: @user.id.to_s)
    Projects::Task.create!(title: "Task #{index}", project: project)
    vendor = Purchasing::Vendor.create!(name: "Vendor #{index}")
    po = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: "PO-N#{index}")
    po.lines.create!(name: "Item #{index}", sku: "ITEM-#{index}", quantity: 2, unit_cost_cents: 100)
    InventoryMovement.create!(sku: "ITEM-#{index}", source: 'square', direction: 'set', delta: 1, quantityBefore: 0, quantityAfter: 1,
      actor: 'system', createdAt: 1.hour.ago)
  end

  test 'list queries do not grow with the number of rows' do
    checks = [[Mcp::Tools::CustomerInsights, { 'view' => 'top' }], [Mcp::Tools::CustomerInsights, { 'view' => 'new' }],
              [Mcp::Tools::ListProjects, {}], [Mcp::Tools::PurchaseOrders, { 'include_lines' => true }],
              [Mcp::Tools::PurchaseOrders, { 'view' => 'vendors' }], [Mcp::Tools::StockMovements, {}]]
    2.times { |index| add_rows(index) }
    few = checks.map { |klass, args| queries { klass.new(token: @token).call(args) } }
    (2...8).each { |index| add_rows(index) }
    many = checks.map { |klass, args| queries { klass.new(token: @token).call(args) } }
    checks.each_with_index do |(klass, args), index|
      assert_operator many[index], :<=, few[index], "#{klass.tool_name} #{args.to_json} ran more queries for more rows (N+1)"
    end
  end
end
