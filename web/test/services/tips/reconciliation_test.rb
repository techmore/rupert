# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/dejavoo_spin_fixture'

# Settling the tip ledger against settled money: batch close, gateway settlement with a changed
# tip, refunds, a batch that lands after the pay period is locked, and the period report.
class TipsReconciliationTest < ActiveSupport::TestCase
  include DejavooSpinFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @store = Location.create!(source: 'ctrax', externalId: 'tips/2', name: 'Settle store')
    @setting = PosSetting.create!(location: @store, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials,
      webhook_signing_key: 'feed-key-for-tests-000002')
    user = User.create!(tenant: Current.tenant, name: 'Cal', email: 'cal-settle@example.com', role: 'cashier', password: 'password')
    @cal = People::Employee.create!(user: user, first_name: 'Cal', last_name: 'Settle', employment_type: 'part_time')
    @at = Time.zone.parse('2026-11-05 14:00')
    ClockShift.create!(user: user, employee: @cal, employee_key: @cal.id.to_s, employee_name: @cal.name, employment_type: 'part_time',
      started_at: @at - 2.hours, ended_at: @at + 2.hours, request_token: SecureRandom.uuid, location_id: @store.id, source: 'pos')
  end

  teardown { Current.reset }

  test 'a Dejavoo batch close settles every estimated tip in that batch' do
    sale = feed_sale(tip: 300, batch: '470')
    Tips::Attribution.call(sale)
    assert_equal 'estimated', TipAllocation.sole.status
    settlement = DejavooFeedEvent.create!(pos_setting: @setting, feed_id: 'settle-470', request_type: 'N', event_type: 'Settlement', tpn: TPN, batch_number: '470',
      settlement_count: 1, settlement_cents: 1466, received_at: @at + 8.hours)
    Tips::Reconciliation.new.settle_dejavoo_batch(settlement)
    row = TipAllocation.sole
    assert_equal ['settled', 'dejavoo-batch:470'], [row.status, row.settlement_ref]
    assert settlement.reload.tip_attributed_at
  end

  test 'an Authorize.net settlement settles the FEED rows and writes the difference when the settled tip changed' do
    sale = feed_sale(tip: 300, reference: 'RDsettle0001')
    Tips::Attribution.call(sale)
    txn = anet(tip: 3.50, invoice: 'RDsettle0001', settlement_state: 'settledSuccessfully', batch: 'B9')
    delta = Tips::Reconciliation.new.authorize_net_transaction(txn)
    assert_equal 50, delta.sum(&:amount_cents)
    assert_equal 'Tip adjusted at settlement', delta.first.note
    assert_equal 350, TipAllocation.sum(:amount_cents)
    assert TipAllocation.all.all? { |r| r.status == 'settled' && r.settlement_ref == 'anet:B9' }
    assert_empty Tips::Reconciliation.new.authorize_net_transaction(txn), 'running again adds nothing'
  end

  test 'a gateway refund reverses the allocations it undoes' do
    txn = anet(tip: 2.00, invoice: 'RDrefund0001', id: '700001', settlement_state: 'settledSuccessfully', batch: 'B1')
    Tips::Reconciliation.new.authorize_net_transaction(txn)
    assert_equal 200, TipAllocation.sum(:amount_cents)
    refund = AuthorizeNetTransaction.create!(environment: 'sandbox', gateway_id: 'g1', source_transaction_id: '700002', reference_transaction_id: '700001',
      transaction_type: 'refundTransaction', payment_status: 'refundSettledSuccessfully', submitted_at: @at + 2.days, authorized_amount: 10, settled_amount: 10, observed_at: Time.current)
    Tips::Reconciliation.new.authorize_net_transaction(refund)
    assert_equal 0, TipAllocation.sum(:amount_cents)
    assert_equal 1, TipAllocation.where.not(reverses_id: nil).count
  end

  test 'a batch that settles after the pay period is locked is carried into the next open period' do
    sale = feed_sale(tip: 400, batch: '480')
    Tips::Attribution.call(sale)
    period = PayPeriod.for_date(Date.new(2026, 11, 5))
    period.lock!(by: Current.user)
    txn = anet(tip: 5.00, invoice: 'none', settlement_state: 'settledSuccessfully', batch: 'B2', submitted_at: Time.zone.parse('2026-11-06 10:00'))
    rows = Tips::Reconciliation.new.authorize_net_transaction(txn)
    assert_equal 1, rows.size
    assert_equal 'carried', rows.first.status
    assert_operator rows.first.pay_period_start, :>, period.ends_on
    assert_equal Date.new(2026, 11, 6), rows.first.business_date
  end

  test 'the period report sums every row so reversed pairs net to zero' do
    sale = feed_sale(tip: 300, rrn: '428209500777')
    Tips::Attribution.call(sale)
    void = DejavooFeedEvent.create!(pos_setting: @setting, feed_id: 'void-777', request_type: 'N', event_type: 'Transaction', sub_event_type: 'VOID', tpn: TPN,
      original_rrn: '428209500777', amount_cents: 1166, tip_cents: 0, host_response_code: '00', received_at: @at + 5.minutes)
    Tips::Attribution.call(void)
    Tips::Declare.call(worker: @cal, amount_cents: 1200, on: '2026-11-05')
    report = Tips::ReconciliationReport.for(*PayRules.current.period_range(Date.new(2026, 11, 5)))
    assert_equal({ terminal: 300, settled: 0, cash: 1200, reversed: -300, total: 1200 },
      report.totals.slice(:terminal_cents, :settled_cents, :cash_cents, :reversed_cents, :total_cents).transform_keys { |k| k.to_s.delete_suffix('_cents').to_sym })
    row = report.by_employee.sole
    assert_equal [0, 1200, 1200], [row.card_cents, row.cash_cents, row.final_cents]
    assert_includes report.to_csv, 'Cal Settle'
  end

  test 'run attributes what the webhook job missed' do
    feed_sale(tip: 100)
    assert_difference -> { TipAllocation.count }, 1 do
      Tips::Reconciliation.new.run
    end
  end

  private

  def feed_sale(tip:, batch: '469', reference: '0', rrn: SecureRandom.random_number(10**12).to_s)
    DejavooFeedEvent.create!(pos_setting: @setting, feed_id: SecureRandom.uuid, request_type: 'N', event_type: 'Transaction', sub_event_type: 'SALE', tpn: TPN,
      transaction_id: SecureRandom.hex(8), external_reference_id: reference, rrn: rrn, batch_number: batch, amount_cents: 1166, tip_cents: tip,
      host_response_code: '00', occurred_on: '2026-11-05', received_at: @at)
  end

  def anet(tip:, invoice:, id: '600001', settlement_state: nil, batch: nil, submitted_at: @at)
    AuthorizeNetTransaction.create!(environment: 'sandbox', gateway_id: 'g1', source_transaction_id: id, transaction_type: 'authCaptureTransaction',
      payment_status: settlement_state ? 'settledSuccessfully' : 'capturedPendingSettlement', submitted_at: submitted_at, settled_at: settlement_state && submitted_at + 1.day,
      settlement_state: settlement_state, source_batch_id: batch, invoice_number: invoice, authorized_amount: 10, settled_amount: 10, tip_amount: tip, observed_at: Time.current)
  end
end
