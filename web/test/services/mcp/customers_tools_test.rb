# frozen_string_literal: true

require 'test_helper'

class CustomersToolsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @user.update!(name: 'Derek Owner')
    Current.tenant = @tenant
    Current.user = @user
    @token = TeamChat::Token.new(@user)
    @asha = customer('Asha', 'Patel', email: 'asha@example.com', phone: '555-0142', tags: 'wholesale, tea club', crm_status: 'vip',
      notes: 'Prefers loose leaf. Call 555 010 0188 or asha.home@example.com.')
    @ravi = customer('Ravi', 'Patel')
    @leo = customer('Leo', 'Brandt')
    @old = customer('Olga', 'Stone')
  end

  teardown { Current.reset }

  def customer(first, last, **attrs)
    Core::Customer.create!({ source: 'manual', external_id: "manual:#{SecureRandom.hex(4)}", first_name: first, last_name: last }.merge(attrs))
  end

  def order(who, at:, cents:, number: SecureRandom.hex(3), paid: true, channel: 'online', item: 'Calm Gummies 30ct')
    row = Core::Order.create!(source: 'shopify', source_order_id: "t-#{number}", order_number: "##{number}", occurred_at: at,
      gross_cents: cents, tax_cents: 0, currency: 'USD', channel: channel, customer: who)
    row.mark_paid! if paid
    row.order_lines.create!(name: item, sku: item.parameterize, unit_cents: cents, quantity: 2, line_cents: cents)
    row
  end

  def lookup(args) = Mcp::Tools::CustomerLookup.new(token: @token).call(args)
  def insights(args = {}) = Mcp::Tools::CustomerInsights.new(token: @token).call(args)

  test 'customer_lookup finds the best name match with lifetime value, history and no contact details' do
    first = order(@asha, at: 200.days.ago, cents: 4000, number: '10401', item: 'Sleep Tincture')
    order(@asha, at: 20.days.ago, cents: 6000, number: '10482')
    order(@asha, at: 5.days.ago, cents: 1000, number: '10490', paid: false)
    first.refunds.create!(amount_cents: 500, method: 'card', refunded_at: 150.days.ago)
    CustomerFollowUp.create!(customer: @asha, author_id: @user.id, owner_id: @user.id, title: 'Call about the tea club', due_on: Date.current - 2)
    CustomerInteraction.create!(customer: @asha, author_id: @user.id, kind: 'call', body: 'Asked about refills; reach her at 555-010-0199.')

    outcome = lookup({ 'query' => "Mrs. Patel's", 'from' => (Date.current - 30).iso8601 })
    data = outcome.data
    assert_equal @asha.id, data[:customer][:id]
    assert_equal ['tea club', 'wholesale'], data[:customer][:tags]
    assert_equal 'vip', data[:customer][:crm_status]
    assert data[:customer][:email_on_file]
    assert_equal [{ id: @ravi.id, name: 'Ravi Patel', crm_status: 'customer', paid_orders: 0 }], data[:other_matches]
    assert_equal 2, data[:total_matches]

    lifetime = data[:lifetime]
    assert_equal 2, lifetime[:paid_orders]
    usd = lifetime[:spend_by_currency].first
    assert_equal ['USD', 10_000, '100.00', 5000, 6000], usd.values_at(:currency, :cents, :dollars, :average_order_cents, :biggest_order_cents)
    assert_equal 20, lifetime[:days_since_last_order]
    assert_equal({ 'paid' => 2, 'placed' => 1 }, lifetime[:orders_by_status])
    assert_equal 500, lifetime[:refunds_by_currency].first[:cents]
    assert_equal [1, 6000], [data[:period][:paid_orders], data[:period][:spend_by_currency].first[:cents]]
    assert_equal 'Calm Gummies 30ct', data[:usually_buys].first[:name]

    assert_equal %w[#10490 #10482 #10401], data[:recent_orders].map { |row| row[:number] }
    assert_equal [{ name: 'Calm Gummies 30ct', sku: 'calm-gummies-30ct', quantity: 2 }], data[:recent_orders].first[:items]
    assert_equal [1, 1], data[:follow_ups].values_at(:open, :overdue)
    assert_equal 'Derek Owner', data[:follow_ups][:rows].first[:owner]
    assert_equal({ 'call' => 1 }, data[:interactions][:by_kind])
    assert_includes data[:interactions][:rows].first[:summary], '[phone hidden]'
    assert_equal false, data[:subscriptions][:stored]

    json = data.to_json
    ['asha@example.com', '555-0142', '555-010-0199', 'asha.home@example.com', '555 010 0188'].each { |secret| refute_includes json, secret }
    assert_includes data[:customer][:notes], '[email hidden]'
    assert_match(/\AAsha Patel \(id \d+, vip, tags: tea club, wholesale\): 2 paid orders, 100.00 USD lifetime/, outcome.text)
    assert_match(/Also matched: Ravi Patel/, outcome.text)
  end

  test 'customer_lookup by id or order number, and explains what it cannot find' do
    order(@leo, at: 3.days.ago, cents: 2500, number: '10482')
    order(nil, at: 3.days.ago, cents: 900, number: '20001')

    assert_equal @leo.id, lookup({ 'order_number' => '10482' }).data[:customer][:id]
    assert_equal @leo.id, lookup({ 'query' => '#10482' }).data[:customer][:id]
    assert_equal @leo.id, lookup({ 'customer_id' => @leo.id }).data[:customer][:id]
    assert_equal @leo.id, lookup({ 'query' => @leo.id.to_s }).data[:customer][:id]
    assert_equal 'Leo Brandt', lookup({ 'query' => 'leo' }).data[:customer][:name]
    assert_equal 0, lookup({ 'query' => 'Ravi Patel' }).data[:lifetime][:paid_orders]

    error = assert_raises(Mcp::ToolError) { lookup({ 'order_number' => '20001' }) }
    assert_match(/no customer linked/, error.message)
    assert_equal 'not_found', assert_raises(Mcp::ToolError) { lookup({ 'query' => 'Nobody Here' }) }.kind
    assert_raises(Mcp::ToolError) { lookup({}) }
  end

  test 'interprets SQLite aggregate timestamps as UTC before applying the app time zone' do
    helper = Object.new.extend(Mcp::Tools::CustomerLookup::Shared)

    timestamp = helper.send(:time_value, '2025-12-30 00:30:00')

    assert_equal Date.new(2025, 12, 29), timestamp.to_date
  end

  test 'customer_insights ranks top, new, repeat and lapsed customers in SQL' do
    order(@asha, at: 200.days.ago, cents: 4000)
    order(@asha, at: 20.days.ago, cents: 6000)
    order(@asha, at: 10.days.ago, cents: 2000, channel: 'pos')
    order(@leo, at: 5.days.ago, cents: 3000)
    order(@old, at: 300.days.ago, cents: 9000)
    order(nil, at: 2.days.ago, cents: 1000)
    order(@ravi, at: 1.day.ago, cents: 5000, paid: false)

    top = insights({ 'view' => 'top', 'from' => (Date.current - 29).iso8601 })
    assert_equal [@asha.id, @leo.id], top.data[:rows].map { |row| row[:customer_id] }
    assert_equal [8000, '80.00', 2, 66.7], top.data[:rows].first.values_at(:spend_cents, :spend_dollars, :orders, :share_percent)
    assert_equal [2, 1], top.data[:counts].values_at(:customers, :orders_without_customer)
    assert_match(/2 customers bought\. Top: Asha Patel 80.00 USD \(2 orders\)/, top.text)
    assert_equal [@asha.id], insights({ 'view' => 'top', 'channel' => 'pos' }).data[:rows].map { |row| row[:customer_id] }
    assert_equal [@leo.id], insights({ 'view' => 'top', 'crm_status' => 'customer', 'from' => (Date.current - 29).iso8601 }).data[:rows].map { |row| row[:customer_id] }
    paged = insights({ 'view' => 'top', 'per_page' => 1 })
    assert_equal [1, true], [paged.data[:rows].size, paged.data[:meta][:has_more]]

    fresh = insights({ 'view' => 'new', 'from' => (Date.current - 29).iso8601 })
    assert_equal [@leo.id], fresh.data[:rows].map { |row| row[:customer_id] }
    assert_equal [1, 1, 2], fresh.data[:counts].values_at(:new_customers, :returning_customers, :customers_who_bought)
    assert_equal 3000, fresh.data[:rows].first[:lifetime_spend].first[:cents]

    repeat = insights({ 'view' => 'repeat', 'from' => (Date.current - 29).iso8601 })
    assert_equal [@asha.id], repeat.data[:rows].map { |row| row[:customer_id] }
    assert_equal [1, 2, 50.0, 3, 66.7], repeat.data[:counts].values_at(:repeat_customers, :customers_who_bought, :repeat_rate_percent, :linked_orders, :repeat_order_share_percent)
    assert_equal 8000, repeat.data[:rows].first[:spend_in_range].first[:cents]

    lapsed = insights({ 'view' => 'lapsed' })
    assert_equal [@old.id], lapsed.data[:rows].map { |row| row[:customer_id] }
    assert_equal [1, 2], lapsed.data[:counts].values_at(:lapsed_customers, :active_customers)
    assert_equal 300, lapsed.data[:rows].first[:days_since_last_order]
    assert_equal [@old.id], insights({ 'view' => 'lapsed', 'days' => 7, 'max_orders' => 1 }).data[:rows].map { |row| row[:customer_id] }
    assert_equal [@asha.id, @old.id], insights({ 'view' => 'lapsed', 'days' => 7 }).data[:rows].map { |row| row[:customer_id] }
    assert_raises(Mcp::ToolError) { insights({ 'view' => 'top', 'from' => '2026-10-10', 'to' => '2026-10-01' }) }
  end

  test 'customer_insights lists follow-ups by owner, interactions, segments, and says subscriptions are not stored' do
    jan = User.create!(email: 'jan-crm@example.com', password: 'password123', role: 'manager', tenant_id: @tenant.id, name: 'Jan Keeper')
    CustomerFollowUp.create!(customer: @asha, author_id: @user.id, owner_id: jan.id, title: 'Send samples', due_on: Date.current - 3)
    CustomerFollowUp.create!(customer: @leo, author_id: @user.id, owner_id: @user.id, title: 'Call back', due_on: Date.current)
    CustomerFollowUp.create!(customer: @leo, author_id: @user.id, title: 'Next month', due_on: Date.current + 30)
    CustomerFollowUp.create!(customer: @ravi, author_id: @user.id, title: 'Done', due_on: Date.current - 1, completed_at: 1.day.ago)

    due = insights({ 'view' => 'follow_ups' })
    assert_equal ['Send samples', 'Call back'], due.data[:rows].map { |row| row[:title] }
    assert_equal [3, 2, 1, 1, 1], due.data[:counts].values_at(:open, :due, :due_today, :overdue, :completed_in_range)
    assert_equal({ 'Jan Keeper' => 1, 'Derek Owner' => 1 }, due.data[:counts][:by_owner])
    assert_equal [3, 'Jan Keeper', 'Asha Patel'], due.data[:rows].first.values_at(:days_overdue, :owner, :customer)
    assert_match(/\A2 customer follow-ups due \(1 overdue, 1 today\), 3 open in all/, due.text)
    assert_equal ['Send samples'], insights({ 'view' => 'follow_ups', 'owner' => 'jan' }).data[:rows].map { |row| row[:title] }
    assert_equal ['Call back'], insights({ 'view' => 'follow_ups', 'owner' => 'me' }).data[:rows].map { |row| row[:title] }
    assert_equal ['Next month'], insights({ 'view' => 'follow_ups', 'status' => 'open', 'owner' => 'unassigned' }).data[:rows].map { |row| row[:title] }
    assert_equal ['Done'], insights({ 'view' => 'follow_ups', 'status' => 'completed' }).data[:rows].map { |row| row[:title] }
    assert_raises(Mcp::ToolError) { insights({ 'view' => 'follow_ups', 'owner' => 'Zed' }) }

    CustomerInteraction.create!(customer: @asha, author_id: jan.id, kind: 'call', body: 'Complained about shipping, email me at a@b.co')
    CustomerInteraction.create!(customer: @leo, author_id: @user.id, kind: 'email', body: 'Sent refund confirmation')
    CustomerInteraction.create!(customer: @leo, author_id: @user.id, kind: 'note', body: 'Old note').update_columns(created_at: 200.days.ago)
    talks = insights({ 'view' => 'interactions', 'from' => (Date.current - 6).iso8601 })
    assert_equal [2, 2, { 'call' => 1, 'email' => 1 }], talks.data[:counts].values_at(:interactions, :customers, :by_kind)
    refute_includes talks.data.to_json, 'a@b.co'
    assert_equal ['call'], insights({ 'view' => 'interactions', 'kind' => 'call' }).data[:rows].map { |row| row[:kind] }
    assert_equal ['Jan Keeper'], insights({ 'view' => 'interactions', 'owner' => 'Jan' }).data[:rows].map { |row| row[:by] }

    segments = insights({ 'view' => 'segments', 'crm_status' => 'vip' })
    assert_equal({ 'vip' => 1, 'customer' => 3 }, segments.data[:counts][:by_crm_status])
    assert_equal({ 'tea club' => 1, 'wholesale' => 1 }, segments.data[:counts][:top_tags])
    assert_equal [@asha.id], segments.data[:rows].map { |row| row[:customer_id] }
    assert_equal [@asha.id], insights({ 'view' => 'segments', 'tag' => 'Tea Club' }).data[:rows].map { |row| row[:customer_id] }
    assert_equal 4, insights({ 'view' => 'segments', 'added_in_range' => true }).data[:counts][:matching]

    subscriptions = insights({ 'view' => 'subscriptions' })
    assert_equal false, subscriptions.data[:stored]
    assert_match(/does not record subscriptions/, subscriptions.text)
  end

  test 'customer tools need customers:read' do
    assert Mcp::Tools::CustomerLookup.available_to?(@token)
    reporter = User.create!(email: 'reports-only@example.com', password: 'password123', role: 'reporting', tenant_id: @tenant.id)
    refute Mcp::Tools::CustomerLookup.available_to?(TeamChat::Token.new(reporter))
    refute Mcp::Tools::CustomerInsights.available_to?(TeamChat::Token.new(reporter))
  end
end
