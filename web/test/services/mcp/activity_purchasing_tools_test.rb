# frozen_string_literal: true

require 'test_helper'

class ActivityPurchasingToolsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @token = TeamChat::Token.new(@user)
  end

  teardown { Current.reset }

  def person(name, role: 'admin')
    User.create!(tenant: @tenant, email: "#{name.parameterize}@example.com", password: 'password123', role: role, name: name)
  end

  def tool(klass, args = {}) = klass.new(token: @token).call(args)

  def place(vendor, number, lines:, expected: nil)
    order = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: number, expected_date: expected)
    lines.each { |name, quantity, cents| order.lines.create!(name: name, sku: name.upcase.tr(' ', '-'), quantity: quantity, unit_cost_cents: cents) }
    order.place_order!
    order
  end

  def receive(order, totals)
    PurchaseReceiving.call(order: order, totals: totals.transform_keys { |line| line.id.to_s }.transform_values(&:to_s),
      token: SecureRandom.uuid, actor: @user)
  end

  test 'activity_log filters by person, action and record and hides contact details' do
    sean = person('Sean Dolbec')
    sean.update_columns(last_active_at: 2.hours.ago)
    vendor = Purchasing::Vendor.create!(name: 'Bottle Co')
    po = Purchasing::PurchaseOrder.create!(vendor: vendor, order_number: 'PO-1042')
    ActivityLogger.log('po_placed', subject: po, actor: sean)
    ActivityLogger.log('settings_saved', actor: sean,
      details: 'Changed by jo@example.com from 192.168.1.20 / 2001:db8::1 using Mozilla/5.0 (X11; Linux) at 10:30:15, call 555-123-4567')
    ActivityLogger.log('mcp_tool_call', actor: sean, details: 'tool sales_summary')
    ActivityLogger.log('expense_updated', actor: @user, details: 'Amount 12.50')
    ::ActivityLog.create!(action: 'expense_recorded', actor_name: 'jo.smith@example.com', subject_label: 'jo.smith@example.com')
    ActivityLogger.log('po_cancelled', subject: po, actor: sean).update_columns(created_at: 60.days.ago)

    outcome = tool(Mcp::Tools::ActivityLog, { 'user' => 'sean' })
    data = outcome.data
    assert_equal %w[settings_saved po_placed], data[:rows].map { |row| row[:action] }
    assert_equal 2, data[:total]
    assert_equal 'Sean Dolbec', data[:rows].first[:who]
    assert_equal [{ name: 'Sean Dolbec', active: true, last_active_at: sean.last_active_at.iso8601 }], data[:people]
    details = data[:rows].first[:details]
    %w[jo@example.com 192.168 2001:db8 Mozilla 555-123].each { |secret| assert_not_includes details, secret }
    assert_includes details, '10:30:15'
    assert_match(/\A2 activity entries .* \(user sean\)\. Most common: /, outcome.text)

    everything = tool(Mcp::Tools::ActivityLog).data
    assert_not_includes everything[:rows].map { |row| row[:action] }, 'mcp_tool_call'
    assert_not_includes everything.to_s, '@example.com'
    assert_includes everything[:rows].map { |row| row[:who] }, 'Jo Smith'
    assert_equal 1, everything[:counts_by_action]['po_placed']
    assert_includes tool(Mcp::Tools::ActivityLog, { 'include_assistant_calls' => true }).data[:rows].map { |row| row[:action] }, 'mcp_tool_call'

    record = tool(Mcp::Tools::ActivityLog, { 'record_type' => 'PurchaseOrder', 'from' => (Date.current - 90).iso8601 }).data
    assert_equal %w[po_placed po_cancelled], record[:rows].map { |row| row[:action] }
    assert_equal ['PurchaseOrder', 'PO-1042'], record[:rows].first.values_at(:record_type, :record)
    assert_equal 2, tool(Mcp::Tools::ActivityLog, { 'action' => 'expense_' }).data[:total]
    assert_equal 1, tool(Mcp::Tools::ActivityLog, { 'group' => 'money', 'query' => '12.50' }).data[:total]
    assert_raises(Mcp::ToolError) { tool(Mcp::Tools::ActivityLog, { 'from' => '2026-10-10', 'to' => '2026-10-01' }) }
  end

  test 'activity, purchasing and movement tools follow the person\'s permissions' do
    manager = TeamChat::Token.new(person('Mia Manager', role: 'manager'))
    assert Mcp::Tools::ActivityLog.available_to?(@token)
    assert Mcp::Tools::PurchaseOrders.available_to?(@token)
    assert_not Mcp::Tools::ActivityLog.available_to?(manager)
    assert_not Mcp::Tools::PurchaseOrders.available_to?(manager)
    assert Mcp::Tools::StockMovements.available_to?(manager)
  end

  test 'purchase_orders lists orders with totals, overdue and partial deliveries, and lines for a PO search' do
    bottles = Purchasing::Vendor.create!(name: 'Bottle Co', email: 'sales@bottles.example', phone: '555-222-3333', contact_name: 'Pat')
    tea = Purchasing::Vendor.create!(name: 'Tea House')
    late = place(bottles, 'PO-1042', lines: [['Amber bottle', 100, 25], ['Dropper', 50, 10]], expected: Date.current - 3)
    receive(late, late.lines.first => 40)
    done = place(tea, 'PO-1043', lines: [['Peppermint tea', 10, 300]], expected: Date.current + 5)
    ::ActivityLog.create!(action: 'po_placed', subject_type: 'Purchasing::PurchaseOrder', subject_id: done.id.to_s, actor_name: 'Admin',
      created_at: 12.days.ago)
    receive(done, done.lines.first => 10)
    done.update_columns(received_date: Date.current - 2)
    Purchasing::PurchaseOrder.create!(vendor: tea, order_number: 'PO-1044')

    outcome = tool(Mcp::Tools::PurchaseOrders)
    data = outcome.data
    assert_equal({ 'ordered' => 1, 'received' => 1, 'draft' => 1 }, data[:counts_by_status])
    assert_equal [1, 1], data.values_at(:overdue, :partial)
    totals = data[:totals].first
    assert_equal [6000, 4000, 2000], totals.values_at(:placed_total_cents, :received_cents, :open_due_cents)
    assert_equal '20.00', totals[:open_due_dollars]
    row = data[:rows].find { |r| r[:order_number] == 'PO-1042' }
    assert_equal [true, 3, true, 2, 150, 40], row.values_at(:overdue, :days_overdue, :partial_delivery, :line_count, :units_ordered, :units_received)
    assert_equal 'Bottle Co', row[:vendor]
    assert_equal [60, 50], row[:lines].map { |line| line[:short] }
    received = data[:rows].find { |r| r[:order_number] == 'PO-1043' }
    assert_equal [(Date.current - 12).iso8601, (Date.current - 2).iso8601, 10], received.values_at(:ordered_on, :received_on, :lead_days)
    assert_match(/\A3 purchase orders: .*1 overdue\. Placed total 60\.00 USD, still due 20\.00\./, outcome.text)
    assert_not_includes data.to_s, 'bottles.example'

    search = tool(Mcp::Tools::PurchaseOrders, { 'query' => '1042' }).data
    assert_equal ['PO-1042'], search[:rows].map { |r| r[:order_number] }
    assert_equal ['PO-1043'], tool(Mcp::Tools::PurchaseOrders, { 'query' => 'peppermint' }).data[:rows].map { |r| r[:order_number] }
    assert_equal ['PO-1042'], tool(Mcp::Tools::PurchaseOrders, { 'overdue_only' => true }).data[:rows].map { |r| r[:order_number] }
    assert_equal ['PO-1042'], tool(Mcp::Tools::PurchaseOrders, { 'status' => 'open' }).data[:rows].map { |r| r[:order_number] }
    assert_equal ['PO-1043'], tool(Mcp::Tools::PurchaseOrders, { 'vendor' => 'tea', 'status' => 'received' }).data[:rows].map { |r| r[:order_number] }
    window = tool(Mcp::Tools::PurchaseOrders, { 'from' => (Date.current - 20).iso8601, 'to' => (Date.current - 5).iso8601 }).data
    assert_equal ['PO-1043'], window[:rows].map { |r| r[:order_number] }
  end

  test 'purchase_orders vendors view ranks vendors by spend with open orders and lead time' do
    bottles = Purchasing::Vendor.create!(name: 'Bottle Co', email: 'sales@bottles.example', phone: '555-222-3333', address: '1 Main St',
      contact_name: 'Pat', payment_terms: 'net15')
    tea = Purchasing::Vendor.create!(name: 'Tea House')
    Purchasing::Vendor.create!(name: 'Unused Supply')
    place(bottles, 'PO-2001', lines: [['Amber bottle', 100, 25]], expected: Date.current - 1)
    done = place(tea, 'PO-2002', lines: [['Peppermint tea', 2, 300]], expected: Date.current)
    done.update_columns(created_at: 8.days.ago)
    receive(done, done.lines.first => 2)
    done.update_columns(received_date: Date.current - 1)

    outcome = tool(Mcp::Tools::PurchaseOrders, { 'view' => 'vendors' })
    rows = outcome.data[:rows]
    assert_equal ['Bottle Co', 'Tea House', 'Unused Supply'], rows.map { |row| row[:name] }
    first = rows.first
    assert_equal [2500, '25.00', 1, 1, 'Pat', 'net15'], first.values_at(:spend_cents, :spend_dollars, :open_orders, :overdue_orders, :contact_name, :payment_terms)
    assert_equal [7.0, 1, 100], rows.second.values_at(:average_lead_days, :lead_time_orders, :on_time_percent)
    assert_equal 0, rows.last[:spend_cents]
    assert_equal 0, rows.second[:paid_in_window_cents]
    assert_not_includes outcome.data.to_s, 'bottles.example'
    assert_not_includes outcome.data.to_s, 'Main St'
    assert_not_includes outcome.data.to_s, '555-222'
    assert_match(/\A3 vendors\. PO spend .*: 31\.00 USD\. Bottle Co 25\.00 \(1 open\); Tea House 6\.00 \(0 open, lead 7\.0d\)/, outcome.text)
  end

  test 'stock_movements lists item and bulk ledger changes newest first' do
    InventoryMovement.create!(sku: 'TEA-50', source: 'square', direction: 'set', delta: -3, quantityBefore: 10, quantityAfter: 7,
      reason: 'Synced from Square', reference: 'sync', actor: 'system', createdAt: 1.day.ago)
    InventoryMovement.create!(sku: 'TEA-50', source: 'negative-fix', direction: 'in', delta: 2, quantityBefore: -2, quantityAfter: 0,
      reason: 'Corrected negative Square inventory', actor: 'user', createdAt: 2.hours.ago)
    InventoryMovement.create!(sku: 'BALM-1', source: 'shopify', direction: 'set', delta: 5, quantityBefore: 0, quantityAfter: 5,
      actor: 'system', createdAt: 20.days.ago)

    outcome = tool(Mcp::Tools::StockMovements)
    data = outcome.data
    assert_equal 2, data[:total]
    assert_equal ['negative-fix', 'square'], data[:rows].map { |row| row[:source] }
    assert_equal [{ sku: 'TEA-50', name: nil, net_change: -1 }], data[:net_change_by_sku]
    assert_equal({ 'negative-fix' => 1, 'square' => 1 }, data[:counts_by_source])
    assert_match(/\A2 stock movements .* Biggest net changes: TEA-50 -1\./, outcome.text)
    assert_equal 1, tool(Mcp::Tools::StockMovements, { 'source' => 'square' }).data[:total]
    assert_equal ['BALM-1'], tool(Mcp::Tools::StockMovements, { 'query' => 'balm', 'from' => (Date.current - 30).iso8601 }).data[:rows].map { |row| row[:sku] }

    material = BulkMaterial.create!(name: 'Lavender', unit: 'g')
    lot = BulkLedger.receive(material: material, attributes: { code: 'LAV-1' },
      movement_attributes: { quantity: '500', unit: 'g', reference: 'Delivery' }, actor: @user.email)
    BulkLedger.record(lot: lot, attributes: { kind: 'consume', quantity: '120.5', unit: 'g', reference: 'Balm batch' }, actor: @user.email)

    bulk = tool(Mcp::Tools::StockMovements, { 'ledger' => 'bulk' })
    assert_equal 2, bulk.data[:total]
    assert_equal [{ material: 'Lavender', received_g: 500.0, consumed_g: 120.5, adjusted_g: 0.0 }], bulk.data[:by_material]
    latest = bulk.data[:rows].first
    assert_equal ['consume', -120.5, 'Admin', 379.5, 'LAV-1'], latest.values_at(:kind, :change_g, :recorded_by, :lot_balance_g, :lot)
    assert_not_includes bulk.data.to_s, @user.email
    assert_match(/\A2 bulk material movements .* Lavender in 500\.0g, used 120\.5g\./, bulk.text)
  end
end
