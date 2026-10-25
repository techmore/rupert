# frozen_string_literal: true

require 'test_helper'

# Issue #404: every MCP tool in the registry — not a hand-picked list — answers
# only from the asking person's workspace and only with their current
# permissions, over both paths that run tools: external MCP tokens
# (ApiAccessToken through Mcp::Server) and team chat (TeamChat::Token through
# TeamChat::Toolbox). A tool added to Mcp::Registry is covered automatically;
# one that needs arguments must add them to REQUIRED_ARGS or this test fails.
class RegistryIsolationTest < ActiveSupport::TestCase
  MARK = 'OTHERTENANT'
  LEAK = /#{MARK}|OTHER-TEA|OTHER-BOTTLE|PO-OTHER|77001|other-secret\.csv/io

  # Arguments for tools whose schema requires some. Kept explicit so a new
  # tool with required arguments cannot slip through untested.
  REQUIRED_ARGS = {
    'metric' => { 'name' => 'gross_sales', 'period' => 'this_month' },
    'marketing_records' => { 'kind' => 'campaigns' },
    'report_context' => ->(test) { { 'report_id' => test.other_feedback.id } },
    'create_task' => { 'title' => 'Restock shelf' },
    'update_task' => ->(test) { { 'task_id' => test.other_task.id, 'status' => 'done' } },
    'submit_feedback' => { 'kind' => 'question', 'summary' => 'Where is the tea report?' }
  }.freeze

  # Extra argument sets that aim straight at the other workspace's rows.
  PROBES = {
    'inventory_search' => [{ 'query' => 'OTHER-TEA' }],
    'list_alerts' => [{ 'status' => 'all' }, { 'query' => 'OTHER-TEA', 'status' => 'all' }],
    'list_tasks' => [{ 'query' => MARK }],
    'list_projects' => [{ 'status' => 'all' }, { 'query' => MARK, 'status' => 'all' }],
    'list_feedback' => [{ 'status' => 'open' }],
    'list_uploads' => [{ 'query' => 'other-secret' }],
    'customer_lookup' => [{ 'query' => MARK }, { 'order_number' => '77001' }],
    'purchase_orders' => [{ 'query' => 'OTHER' }, { 'view' => 'vendors' }],
    'stock_movements' => [{ 'query' => 'OTHER-TEA' }],
    'activity_log' => [{ 'query' => MARK }],
    'customer_insights' => [{ 'view' => 'interactions' }, { 'view' => 'follow_ups', 'status' => 'open' }],
    'marketing_records' => Mcp::Tools::MarketingRecords::KINDS.map { |kind| { 'kind' => kind } }
  }.freeze

  # Search words a tool repeats back ("No customer matches ...") are not leaks.
  ECHOED_KEYS = %w[query order_number tag].freeze

  attr_reader :other_task, :other_feedback

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @other = Tenant.create!(name: 'Other registry workspace', subdomain: 'other-registry')
    seed_other_workspace
    Current.tenant = @tenant
    Current.user = @user
  end

  teardown { Current.reset }

  def seed_other_workspace
    Current.tenant = @other
    stranger = User.create!(tenant: @other, email: 'registry-stranger@example.invalid', password: 'password123', role: 'admin', name: "#{MARK} Stranger")
    Current.user = stranger
    customer = Core::Customer.create!(source: 'manual', external_id: 'manual:other-registry', first_name: MARK, last_name: 'Buyer', crm_status: 'vip', tags: MARK)
    order = Core::Order.create!(source: 'shopify', source_order_id: 'other-registry-1', order_number: '#77001', occurred_at: 2.days.ago,
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
    project = Projects::Project.create!(name: "#{MARK} project", goal: goal)
    @other_task = Projects::Task.create!(title: "#{MARK} task", project: project, priority: 'urgent')
    employee = People::Employee.create!(first_name: MARK, last_name: 'Worker')
    People::ScheduledShift.create!(employee: employee, starts_at: Date.current.in_time_zone + 9.hours, ends_at: Date.current.in_time_zone + 17.hours)
    vendor = Purchasing::Vendor.create!(name: "#{MARK} Vendor")
    po = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: 'PO-OTHER-1')
    po.lines.create!(name: "#{MARK} bottle", sku: 'OTHER-BOTTLE', quantity: 5, unit_cost_cents: 100)
    ActivityLogger.log('po_placed', subject: po, actor: stranger, details: MARK)
    InventoryMovement.create!(sku: 'OTHER-TEA', source: 'square', direction: 'set', delta: -3, quantityBefore: 10, quantityAfter: 7,
      reason: MARK, actor: 'system', createdAt: 1.hour.ago)
    product = ShopifyProduct.create!(id: 'registry-other-product', title: "#{MARK} Tea tin")
    variant = ShopifyVariant.create!(id: 'registry-other-variant', product: product, title: "#{MARK} 50g", sku: 'OTHER-TEA', tracked: true)
    location = Location.create!(source: 'shopify', externalId: 'registry-other-location', name: "#{MARK} shelf")
    InventoryLevel.create!(source: 'shopify', locationId: location.externalId, shopifyVariantId: variant.id, quantity: 1, available: 1)
    StockAlert.create!(shopifyVariantId: variant.id, sku: 'OTHER-TEA', quantity: 1, threshold: 5, status: 'open', note: MARK)
    Finance::Expense.create!(payee: "#{MARK} landlord", category: 'rent', amount_cents: 77_001, incurred_on: Date.current)
    @other_feedback = AgentFeedback.create!(kind: 'bug', source: 'app', user_id: stranger.id, summary: "#{MARK} report", details: MARK)
    Upload.create!(filename: 'other-secret.csv', file_format: 'csv', origin: 'web', status: 'needs_review', byte_size: 10)
  end

  def args_for(tool)
    value = REQUIRED_ARGS[tool.tool_name] || {}
    value.respond_to?(:call) ? value.call(self) : value
  end

  def outcome_text(outcome, args)
    text = outcome.is_a?(Mcp::ToolError) ? outcome.message : "#{outcome.text} #{outcome.data.to_json}"
    args.slice(*ECHOED_KEYS).each_value { |value| text = text.gsub(value.to_s, '') }
    text
  end

  def run_tool(klass, args, token)
    klass.new(token: token).call(args)
  rescue Mcp::ToolError => e
    e
  rescue ActiveRecord::RecordNotFound
    # Mcp::Server answers this as "does not exist in this workspace".
    Mcp::ToolError.new('not found', kind: 'not_found')
  end

  def person(email, permissions: nil, role: 'admin')
    user = User.create!(tenant: @tenant, email: email, password: 'password123', role: role)
    user.update_permission_overrides!(permissions) if permissions
    user.reload
  end

  def mcp_call(token, name, arguments = {})
    payload, = Mcp::Server.new(token: token).handle({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call',
                                                      'params' => { 'name' => name, 'arguments' => arguments } })
    payload[:result]
  end

  def mcp_listed(token)
    payload, = Mcp::Server.new(token: token).handle({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })
    payload.dig(:result, :tools).pluck(:name)
  end

  test 'every tool that needs arguments has sample arguments here' do
    Mcp::Registry.tools.each do |tool|
      required = Array(tool.input_schema[:required]).map(&:to_s)
      next if required.empty?

      assert REQUIRED_ARGS.key?(tool.tool_name), "add #{tool.tool_name} to REQUIRED_ARGS so its isolation is tested"
      assert_empty required - args_for(tool).keys, "#{tool.tool_name} sample arguments miss #{required - args_for(tool).keys}"
    end
  end

  test 'no read-only tool returns another workspace, in team chat or over MCP' do
    operator = person('registry-operator@example.invalid', role: 'super_admin')
    tokens = { 'team chat' => TeamChat::Token.new(operator) }
    api, = ApiAccessToken.issue(attributes: { name: 'Everything', scopes: ApiAccessToken::SCOPES.keys - ApiAccessToken::WRITE_SCOPES },
      user: operator, tenant: @tenant)
    assert api.persisted?, api.errors.full_messages.to_sentence
    tokens['MCP token'] = api
    exercised = []
    Mcp::Registry.tools.select(&:read_only).each do |tool|
      [args_for(tool), *PROBES.fetch(tool.tool_name, [])].uniq.each do |args|
        tokens.each do |path, token|
          assert tool.available_to?(token), "#{tool.tool_name} should be offered to a platform administrator (#{path})"
          outcome = run_tool(tool, args, token)
          assert_no_match LEAK, outcome_text(outcome, args), "#{tool.tool_name} #{args.to_json} returned another workspace's data (#{path})"
        end
        exercised << tool.tool_name
      end
    end
    assert_empty Mcp::Registry.tools.select(&:read_only).map(&:tool_name) - exercised
  end

  test 'control: the seeded rows are visible from inside their own workspace' do
    Current.tenant = @other
    stranger = User.find_by!(email: 'registry-stranger@example.invalid')
    Current.user = stranger
    token = TeamChat::Token.new(stranger)
    # Arguments that do not repeat the marker, so a match can only come from a seeded row.
    { 'list_tasks' => {}, 'list_alerts' => { 'status' => 'all' }, 'list_uploads' => {}, 'list_feedback' => {}, 'inventory_search' => {},
      'customer_lookup' => { 'order_number' => '77001' }, 'purchase_orders' => {}, 'stock_movements' => {}, 'list_projects' => { 'status' => 'all' },
      'customer_insights' => { 'view' => 'interactions' }, 'activity_log' => {} }.each do |name, args|
      tool = Mcp::Registry.find(name)
      outcome = run_tool(tool, args, token)
      assert_kind_of Mcp::Result, outcome, "#{name} failed inside its own workspace: #{outcome.try(:message)}"
      assert_match LEAK, outcome_text(outcome, args), "#{name} control did not find the seeded row, so the isolation check would prove nothing"
    end
  end

  test 'a record id from another workspace is not found, not shown' do
    token = TeamChat::Token.new(@user)
    [[Mcp::Tools::ReportContext, { 'report_id' => other_feedback.id }],
     [Mcp::Tools::ListProjects, { 'project_id' => other_task.project_id }]].each do |klass, args|
      outcome = run_tool(klass, args, token)
      assert_kind_of Mcp::ToolError, outcome, "#{klass.tool_name} answered with another workspace's record"
      assert_no_match LEAK, outcome.message
    end
  end

  test 'write tools only touch the asking workspace' do
    token, = ApiAccessToken.issue(attributes: { name: 'Writer', scopes: %w[tasks:write tasks:read] }, user: @user, tenant: @tenant)
    result = mcp_call(token, 'update_task', args_for(Mcp::Tools::UpdateTask))
    assert result[:isError], 'update_task changed a task in another workspace'
    assert_equal 'todo', Current.set(tenant: @other) { other_task.reload.status }

    assert_difference -> { Projects::Task.unscoped.where(tenant_id: @tenant.id).count }, 1 do
      assert_no_difference -> { Projects::Task.unscoped.where(tenant_id: @other.id).count } do
        assert_not mcp_call(token, 'create_task', args_for(Mcp::Tools::CreateTask))[:isError]
      end
    end
    assert_no_difference -> { AgentFeedback.unscoped.where(tenant_id: @other.id).count } do
      assert_not mcp_call(token, 'submit_feedback', args_for(Mcp::Tools::SubmitFeedback))[:isError]
    end
    assert_equal @tenant.id, AgentFeedback.unscoped.order(:id).last.tenant_id
  end

  test 'each tool is refused once its owner permission is removed, on both paths' do
    Mcp::Registry.tools.select(&:permission).each do |tool|
      owner = person("perm-#{tool.tool_name}@example.invalid")
      api, = ApiAccessToken.issue(attributes: { name: tool.tool_name, scopes: [tool.scope] }, user: owner, tenant: @tenant)
      assert api.persisted?, "#{tool.tool_name}: #{api.errors.full_messages.to_sentence}"
      chat = TeamChat::Token.new(owner, write: tool.scope)
      unless tool.tool_name == 'ai_health'
        assert tool.available_to?(api), "#{tool.tool_name} should be offered with #{tool.scope} and #{tool.permission}"
        assert tool.available_to?(chat), "#{tool.tool_name} should be offered in team chat with #{tool.permission}"
      end

      owner.update_permission_overrides!(User::ROLE_PERMISSIONS.fetch('admin') - [tool.permission])
      owner.reload
      api = ApiAccessToken.unscoped.find(api.id)
      chat = TeamChat::Token.new(owner, write: tool.scope)
      assert_not tool.available_to?(api), "#{tool.tool_name} still offered to a token whose owner lost #{tool.permission}"
      assert_not tool.available_to?(chat), "#{tool.tool_name} still offered in team chat without #{tool.permission}"
      assert_not_includes mcp_listed(api), tool.tool_name
      result = mcp_call(api, tool.tool_name, args_for(tool))
      assert result[:isError], "#{tool.tool_name} answered after #{tool.permission} was removed"
      assert_match(/not allowed to use #{tool.tool_name}/, result.dig(:content, 0, :text))
    end
  end

  test 'a token gets exactly the tools its scopes name, and nothing else' do
    ApiAccessToken::SCOPES.each_key do |scope|
      token, = ApiAccessToken.issue(attributes: { name: "Only #{scope}", scopes: [scope] }, user: @user, tenant: @tenant)
      assert token.persisted?, "#{scope}: #{token.errors.full_messages.to_sentence}"
      listed = mcp_listed(token)
      Mcp::Registry.tools.each do |tool|
        expected = tool.scope.nil? || tool.scope == scope
        expected &&= @user.super_admin? if tool.tool_name == 'ai_health'
        assert_equal expected, listed.include?(tool.tool_name), "#{tool.tool_name} with a #{scope}-only token"
        next if expected

        result = mcp_call(token, tool.tool_name, args_for(tool))
        assert result[:isError], "#{tool.tool_name} answered a #{scope}-only token"
      end
    end
  end

  test 'revoked, expired and employee-owned tokens get no tools' do
    revoked, = ApiAccessToken.issue(attributes: { name: 'Revoked', scopes: ['reports:read'] }, user: @user, tenant: @tenant)
    revoked.update_column(:revoked_at, Time.current)
    expired, = ApiAccessToken.issue(attributes: { name: 'Expired', scopes: ['reports:read'], expires_at: 1.day.from_now }, user: @user, tenant: @tenant)
    travel 2.days do
      [revoked, expired].each do |token|
        assert_empty Mcp::Registry.available_to(token).map(&:tool_name)
        assert mcp_call(token, 'get_workspace_info')[:isError]
      end
    end
    staff = person('registry-staff@example.invalid', role: 'employee')
    assert_empty Mcp::Registry.available_to(TeamChat::Token.new(staff))
  end

  test 'team chat offers write tools only as proposals and never with a write scope' do
    room = Struct.new(:id).new(0)
    toolbox = TeamChat::Toolbox.new(user: @user, room: room, reply: nil)
    kinds = toolbox.definitions.to_h { |definition| [definition.name, definition.kind] }
    Mcp::Registry.tools.reject(&:read_only).each do |tool|
      assert_includes [nil, :write], kinds[tool.tool_name], "#{tool.tool_name} offered to the model as a direct call"
    end
    chat = TeamChat::Token.new(@user)
    ApiAccessToken::WRITE_SCOPES.each { |scope| assert_not chat.allows?(scope), "team chat token allows #{scope} without an approval" }
    offered = kinds.select { |_name, kind| kind == :mcp }.keys
    assert_equal Mcp::Registry.available_to(chat).select(&:read_only).map(&:tool_name).sort, offered.sort

    limited = person('registry-limited@example.invalid', permissions: %w[reports.read])
    offered = TeamChat::Toolbox.new(user: limited, room: room, reply: nil).definitions.select { |definition| definition.kind == :mcp }.map(&:name)
    Mcp::Registry.tools.select(&:permission).each do |tool|
      next if limited.can?(tool.permission)

      assert_not_includes offered, tool.tool_name, "team chat offered #{tool.tool_name} without #{tool.permission}"
    end
  end

  test 'a team chat tool call answers from the asking workspace only' do
    room = Struct.new(:id).new(0)
    toolbox = TeamChat::Toolbox.new(user: @user, room: room, reply: nil)
    %w[list_tasks list_alerts customer_lookup purchase_orders list_uploads].each do |name|
      args = PROBES.fetch(name, [{}]).first
      text = toolbox.call_once(name, args)
      args.slice(*ECHOED_KEYS).each_value { |value| text = text.gsub(value.to_s, '') }
      assert_no_match LEAK, text, "team chat #{name} returned another workspace's data"
    end
  end
end
