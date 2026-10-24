# frozen_string_literal: true

require 'test_helper'

class DailyCloseSummaryTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'store rows give gross after discounts before tax, net, tax, tips, cash and credit' do
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-14 12:00'),
      gross_cents: 1100, tax_cents: 100, tip_cents: 150, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!
    order.payments.create!(method: 'cash', amount_cents: 400, status: 'completed', paid_at: order.occurred_at)
    order.payments.create!(method: 'card', amount_cents: 700, status: 'completed', paid_at: order.occurred_at)
    row = DailyCloseSummary.new(day: '2026-10-14').store_rows.first
    assert_equal [1000, 0, 1000, 100, 150, 400, 700], [row.gross, row.refunds, row.net, row.tax, row.tips, row.cash, row.credit]
  end

  test 'no data gives an empty summary rather than zeros' do
    assert_predicate DailyCloseSummary.new(day: '2026-10-14'), :empty?
  end

  test 'authorize.net settlements are summarised per gateway and currency, refunds kept apart' do
    settled = Time.zone.parse('2026-10-14 16:00')
    { 'a1' => ['authCaptureTransaction', 'settledSuccessfully', '30.00'], 'a2' => ['authCaptureTransaction', 'settledSuccessfully', '12.25'],
      'r1' => ['refundTransaction', 'refundSettledSuccessfully', '5.00'], 's1' => ['authCaptureTransaction', 'settledSuccessfully', '99.00'] }.each do |id, (type, status, amount)|
      AuthorizeNetTransaction.create!(environment: id == 's1' ? 'sandbox' : 'production', gateway_id: 'gw-1', source_transaction_id: id,
        transaction_type: type, payment_status: status, submitted_at: settled - 1.hour, settled_at: settled,
        authorized_amount: amount, settled_amount: amount, currency: 'USD', observed_at: settled)
    end
    summary = DailyCloseSummary.new(day: '2026-10-14')
    assert_equal [{ account: 'gw-1', currency: 'USD', sales_cents: 4225, sales_count: 2, refund_cents: 500, refund_count: 1 }], summary.authorize_net_rows
    assert_predicate summary, :empty?, 'gateway settlements are never store sales'
  end

  test 'swipesimple close is the same business date' do
    assert_equal Date.new(2026, 10, 14), DailyCloseSummary.new(day: '2026-10-14').swipesimple_close.date
  end
end
