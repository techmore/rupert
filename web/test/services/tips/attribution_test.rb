# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/dejavoo_spin_fixture'

# Who earns a card tip (docs/time-and-pay/DECISIONS.md): pool split with the remainder to the
# earliest clock-in, administrators excluded, unassigned when nobody eligible was there, direct
# when the store keeps tips with the cashier, evidence order, idempotency and re-attribution.
class TipsAttributionTest < ActiveSupport::TestCase
  include DejavooSpinFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @store = Location.create!(source: 'ctrax', externalId: 'tips/1', name: 'Tip store')
    @setting = PosSetting.create!(location: @store, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials,
      webhook_signing_key: 'feed-key-for-tests-000001')
    @ana = worker('ana', 'cashier', number: '12')
    @ben = worker('ben', 'cashier', number: '14')
    @boss = worker('boss', 'admin')
    @at = Time.zone.parse('2026-11-05 12:05')
    clock(@ana, @at - 3.hours, @at + 3.hours)
    clock(@ben, @at - 1.hour, @at + 5.hours)
    clock(@boss, @at - 4.hours, @at + 4.hours)
  end

  teardown { Current.reset }

  test 'a terminal tip is pooled among the eligible people clocked in, remainder to the earliest clock-in, admins excluded' do
    rows = Tips::Attribution.call(sale(tip: 125))
    assert_equal 2, rows.size
    ana, ben = rows.partition { |r| r.employee_id == @ana.id }.map(&:first)
    assert_equal [63, 62], [ana.amount_cents, ben.amount_cents]
    assert_equal ['pool', 'estimated', 2, 125, 'time_register'], [ana.tip_method, ana.status, ana.share_count, ana.gross_tip_cents, ana.evidence]
    assert_equal @store.id, ana.location_id
    assert_equal Date.new(2026, 11, 5), ana.business_date
    assert_nil rows.find { |r| r.employee_id == @boss.id }
  end

  test 'attribution is idempotent and force re-attributes after reversing the old rows' do
    event = sale(tip: 300)
    first = Tips::Attribution.call(event)
    assert_equal first.map(&:id), Tips::Attribution.call(event).map(&:id)
    assert_equal 2, TipAllocation.count
    ClockShift.find_by(employee_id: @ben.id).update!(started_at: @at + 1.hour, ended_at: @at + 5.hours)
    again = Tips::Attribution.call(event, force: true)
    assert_equal 1, again.size
    assert_equal [@ana.id, 300], [again.first.employee_id, again.first.amount_cents]
    assert_equal 300, TipAllocation.sum(:amount_cents), 'reversals and the new split net to the tip'
  end

  test 'nobody eligible on shift leaves the tip unassigned, never dropped' do
    ClockShift.where(employee_id: [@ana.id, @ben.id]).delete_all
    rows = Tips::Attribution.call(sale(tip: 500))
    assert_equal 1, rows.size
    assert rows.first.unassigned?
    assert_equal 500, rows.first.amount_cents
  end

  test 'the checkout cashier is the strongest evidence, then the clerk number, then time and register' do
    user = @ben.user
    display = PosDisplaySession.create!(user: user, location: @store)
    checkout = PosCheckout.create!(location: @store, user: user, pos_display_session: display, cart_revision: 1, reference: 'RDcheckout000001', tender: 'card',
      gateway_provider: 'dejavoo_spin', gateway_fingerprint: @setting.payment_fingerprint, environment: 'sandbox', lines_json: [], subtotal_cents: 1000, tax_cents: 60,
      tip_cents: 200, total_cents: 1260, status: 'paid', paid_at: @at)
    attempt = checkout.pos_payment_attempts.create!(invoice: 'RDcheckout000001', nonce_digest: SecureRandom.hex(32), submitted_at: @at, status: 'paid')
    TimeRules.save!({ 'tip_method' => 'direct' })
    by_checkout = Tips::Attribution.call(sale(tip: 200, reference: attempt.invoice, matched: attempt, performed_by: '12'))
    assert_equal [[@ben.id, 200, 'direct', 'checkout']], by_checkout.map { |r| [r.employee_id, r.amount_cents, r.tip_method, r.evidence] }
    by_clerk = Tips::Attribution.call(sale(tip: 100, id: 'clerk-1', performed_by: '12'))
    assert_equal [[@ana.id, 100, 'direct', 'clerk']], by_clerk.map { |r| [r.employee_id, r.amount_cents, r.tip_method, r.evidence] }
    by_time = Tips::Attribution.call(sale(tip: 100, id: 'time-1'))
    assert_equal %w[pool pool], by_time.map(&:tip_method), 'no cashier known: direct falls back to the pool'
  end

  test 'a void reverses the sale rows and a partial refund reverses the refunded share' do
    original = sale(tip: 400, rrn: '428209500001')
    Tips::Attribution.call(original)
    void = DejavooFeedEvent.create!(pos_setting: @setting, feed_id: 'void-1', request_type: 'N', event_type: 'Transaction', sub_event_type: 'VOID', tpn: TPN,
      original_rrn: '428209500001', amount_cents: 1166, tip_cents: 0, host_response_code: '00', received_at: @at + 10.minutes)
    reversals = Tips::Attribution.call(void)
    assert_equal [-200, -200], reversals.map(&:amount_cents)
    assert_equal 0, TipAllocation.sum(:amount_cents)
    assert_empty Tips::Attribution.call(void), 'a repeated void posting adds nothing'
    assert_equal 0, TipAllocation.sum(:amount_cents)

    second = sale(tip: 400, id: 'sale-2', rrn: '428209500002', amount: 1000)
    Tips::Attribution.call(second)
    refund = DejavooFeedEvent.create!(pos_setting: @setting, feed_id: 'return-1', request_type: 'N', event_type: 'Transaction', sub_event_type: 'RETURN', tpn: TPN,
      original_rrn: '428209500002', amount_cents: 250, tip_cents: 0, host_response_code: '00', received_at: @at + 20.minutes)
    partial = Tips::Attribution.call(refund)
    assert_equal [-50, -50], partial.map(&:amount_cents)
    assert_equal 300, TipAllocation.where(source_kind: 'dejavoo_feed_event', source_id: [second.id, refund.id]).sum(:amount_cents)
  end

  test 'a tip adjustment writes only the difference and a declined sale is ignored' do
    original = sale(tip: 200, rrn: '428209500009')
    Tips::Attribution.call(original)
    adjust = DejavooFeedEvent.create!(pos_setting: @setting, feed_id: 'tipadj-1', request_type: 'N', event_type: 'Transaction', sub_event_type: 'TIPADJUST', tpn: TPN,
      original_rrn: '428209500009', amount_cents: 1166, tip_cents: 300, host_response_code: '00', received_at: @at + 30.minutes)
    delta = Tips::Attribution.call(adjust)
    assert_equal 100, delta.sum(&:amount_cents)
    assert_equal 300, TipAllocation.sum(:amount_cents)
    assert_empty Tips::Attribution.call(sale(tip: 900, id: 'declined', host: '05'))
  end

  test 'an Authorize.net tip is attributed only when no FEED event covers the sale, settled when the gateway settled it' do
    feed = sale(tip: 150, reference: 'RDshared0001')
    Tips::Attribution.call(feed)
    covered = anet(tip: 1.50, invoice: 'RDshared0001')
    assert_empty Tips::Attribution.call(covered)
    alone = anet(tip: 2.00, invoice: 'RDalone0001', id: '900002', settlement_state: 'settledSuccessfully', batch: 'B77')
    rows = Tips::Attribution.call(alone)
    assert_equal 200, rows.sum(&:amount_cents)
    assert rows.all? { |r| r.status == 'settled' && r.settlement_ref == 'anet:B77' }
    refund = AuthorizeNetTransaction.create!(environment: 'sandbox', gateway_id: 'g1', source_transaction_id: '900003', reference_transaction_id: '900002',
      transaction_type: 'refundTransaction', payment_status: 'refundSettledSuccessfully', submitted_at: @at + 1.day, authorized_amount: 10, settled_amount: 10, observed_at: Time.current)
    assert_equal(-200, Tips::Attribution.call(refund).sum(&:amount_cents))
  end

  test 'a Rupert POS cash sale with a tip is a settled cash tip for the people clocked in' do
    order = Core::Order.new(source: 'rupert_pos', source_order_id: 'cash-1', occurred_at: @at, currency: 'USD', gross_cents: 1300, tip_cents: 300, location_id: @store.id)
    order.aasm.current_state = :paid
    order.save!
    rows = Tips::Attribution.call(order)
    assert_equal %w[cash cash], rows.map(&:tip_method)
    assert rows.all? { |r| r.status == 'settled' }
    assert_equal 300, rows.sum(&:amount_cents)
  end

  private

  def worker(name, role, number: nil)
    user = User.create!(tenant: Current.tenant, name: name.capitalize, email: "#{name}-tips@example.com", role: role, password: 'password')
    People::Employee.create!(user: user, first_name: name.capitalize, last_name: 'Tipped', employment_type: 'part_time', employee_number: number)
  end

  def clock(employee, from, to)
    ClockShift.create!(user: employee.user, employee: employee, employee_key: employee.id.to_s, employee_name: employee.name, employment_type: 'part_time',
      started_at: from, ended_at: to, request_token: SecureRandom.uuid, location_id: @store.id, source: 'pos')
  end

  def sale(tip:, id: SecureRandom.uuid, reference: '0', matched: nil, performed_by: nil, rrn: SecureRandom.random_number(10**12).to_s, amount: 1166, host: '00')
    DejavooFeedEvent.create!(pos_setting: @setting, feed_id: id, request_type: 'N', event_type: 'Transaction', sub_event_type: 'SALE', tpn: TPN,
      transaction_id: SecureRandom.hex(8), external_reference_id: reference, rrn: rrn, batch_number: '469', amount_cents: amount, tip_cents: tip,
      host_response_code: host, occurred_on: '2026-11-05', received_at: @at, performed_by: performed_by,
      matched_kind: matched && 'pos_payment_attempt', matched_id: matched&.id)
  end

  def anet(tip:, invoice:, id: '900001', settlement_state: nil, batch: nil)
    AuthorizeNetTransaction.create!(environment: 'sandbox', gateway_id: 'g1', source_transaction_id: id, transaction_type: 'authCaptureTransaction',
      payment_status: settlement_state ? 'settledSuccessfully' : 'capturedPendingSettlement', submitted_at: @at, settled_at: settlement_state && @at + 1.day,
      settlement_state: settlement_state, source_batch_id: batch, invoice_number: invoice, authorized_amount: 10, settled_amount: 10, tip_amount: tip, observed_at: Time.current)
  end
end
