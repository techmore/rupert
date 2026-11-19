# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

# Voids and refunds of Dejavoo terminal sales through SPIn (sandbox fixture).
class DejavooCardReversalTest < ActiveSupport::TestCase
  include DejavooSpinFixture
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-refund/1', name: 'Dejavoo refund store')
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Sandbox', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'dejavoo_spin', environment: 'sandbox', credentials_json: dejavoo_credentials)
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register,
      cart_revision: 1, reference: SecureRandom.hex(16), tender: 'card', gateway_provider: 'dejavoo_spin',
      gateway_fingerprint: @setting.payment_fingerprint, environment: 'sandbox',
      lines_json: [{ 'variant_id' => '7', 'sku' => 'HH-CBD-1', 'category' => 'CBD Isolate', 'title' => 'CBD tincture', 'quantity' => 1, 'unit_price' => '10.05', 'line_total' => '10.05' }],
      subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166)
    prepare_dejavoo_fixture
    Pos::DejavooTerminalPayment.call(@checkout)
    assert @checkout.reload.paid?
    @sale_reference = @checkout.pos_payment_attempts.find_by(status: 'paid').invoice
  end
  teardown { Current.reset }

  def reverse(amount_cents) = Pos::CardReversal.call(checkout: @checkout, amount_cents: amount_cents, reason: 'Customer return', user: @user)

  test 'the whole sale is voided at once while the batch is open' do
    reversal = reverse(1166)
    assert_equal %w[void succeeded], [reversal.kind, reversal.status]
    path, body = @spin_requests.last
    assert_equal 'v2/Payment/Void', path
    assert_equal @sale_reference, body['ReferenceId']
    assert_in_delta 11.66, body['Amount']
    assert_raises(Pos::Error) { reverse(1) }
  end

  test 'a closed batch turns the void into a refund on the terminal' do
    @spin_void_mode = :declined
    refund = reverse(1166)
    assert_equal %w[refund submitting], [refund.kind, refund.status]
    assert_equal 'failed', PosCardReversal.find_by(kind: 'void').status
    assert_enqueued_jobs 1, only: PosTerminalRefundJob
    Current.reset
    perform_enqueued_jobs(only: PosTerminalRefundJob)
    Current.tenant = tenants(:default_tenant)
    assert_equal 'succeeded', refund.reload.status
    path, body = @spin_requests.last
    assert_equal 'v2/Payment/Return', path
    assert_equal refund.reference, body['ReferenceId']
    assert_in_delta 11.66, body['Amount']
  end

  test 'a part refund goes straight to the terminal and only the rest can be refunded after' do
    refund = reverse(500)
    assert_equal 'refund', refund.kind
    perform_enqueued_jobs(only: PosTerminalRefundJob)
    assert_equal 'succeeded', refund.reload.status
    assert_not_includes @spin_requests.map(&:first), 'v2/Payment/Void'
    error = assert_raises(Pos::Error) { reverse(700) }
    assert_includes error.message, '6.66'
  end

  test 'a cancelled refund on the terminal refunds nothing' do
    @spin_return_mode = :canceled
    refund = reverse(500)
    perform_enqueued_jobs(only: PosTerminalRefundJob)
    assert_equal 'failed', refund.reload.status
    assert_includes refund.failure_message, 'cancelled'
  end

  test 'a lost refund answer is never resent and the recheck finds it' do
    @spin_return_mode = :timeout
    refund = reverse(500)
    perform_enqueued_jobs(only: PosTerminalRefundJob)
    assert_equal 'unknown', refund.reload.status
    returns = @spin_requests.count { |path, _| path == 'v2/Payment/Return' }
    assert_equal 1, returns
    @spin_transactions[refund.reference] = { code: '0000', voided: false, total: '5.00', type: 'Return' }
    assert_equal 'unknown', Pos::CardReversal.reconcile!(refund).status, 'the terminal may still be waiting'
    travel(Pos::DejavooTerminalPayment::IN_FLIGHT + 1.second) do
      assert_equal 'succeeded', Pos::CardReversal.reconcile!(refund).status
    end
    assert_equal 1, @spin_requests.count { |path, _| path == 'v2/Payment/Return' }
  end

  test 'a sale voided on the terminal outside Rupert is not reversed again' do
    @spin_transactions[@sale_reference][:voided] = true
    assert_raises(Pos::Error) { reverse(1166) }
    assert_empty PosCardReversal.all
  end

  test 'a paid terminal sale remembers its batch and card type, and refunds reuse the card type' do
    attempt = @checkout.pos_payment_attempts.find_by(status: 'paid')
    assert_equal %w[7 Credit], [attempt.batch_number, attempt.payment_type]
    refund = reverse(500)
    perform_enqueued_jobs(only: PosTerminalRefundJob)
    assert_equal '7', refund.reload.batch_number
    _, body = @spin_requests.last
    assert_equal 'Credit', body['PaymentType']
  end

  test 'closing the batch compares the terminal totals with Rupert' do
    results = Pos::DejavooBatchClose.call(@setting)
    assert_equal 1, results.size
    result = results.first
    assert_equal 2550, result.dejavoo_total_cents
    assert_not result.balanced?, 'the fixture batch holds sales Rupert did not make'
    assert_includes result.summary, 'differ'
    assert_includes @spin_requests.map(&:first), 'v2/Payment/Settle'
  end
end
