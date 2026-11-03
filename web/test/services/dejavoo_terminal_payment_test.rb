# frozen_string_literal: true

require 'test_helper'
require_relative '../support/dejavoo_spin_fixture'

class DejavooTerminalPaymentTest < ActiveSupport::TestCase
  include DejavooSpinFixture
  include ActiveSupport::Testing::TimeHelpers

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'dejavoo-pay/1', name: 'Dejavoo sandbox store')
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
  end
  teardown { Current.reset }

  def attempt = @checkout.pos_payment_attempts.order(:id).last

  test 'an approved terminal sale gives one sandbox receipt with no revenue or stock effect' do
    before_register = @register.attributes
    Pos::DejavooTerminalPayment.call(@checkout)
    assert @checkout.reload.paid?
    assert @checkout.receipt[:sandbox]
    assert_equal({ processor: 'Dejavoo terminal', brand: 'Visa', last_four: '1111', auth_code: 'A1B2C3' }, @checkout.receipt[:card].slice(:processor, :brand, :last_four, :auth_code))
    assert_equal '987654321', attempt.transaction_id
    assert_equal before_register, @register.reload.attributes
    assert_empty Core::Order.where(source: 'rupert_pos')
    _, sale = @spin_requests.first
    assert_equal attempt.invoice, sale['ReferenceId']
    assert_in_delta 10.65, sale['Amount']
    assert_in_delta 1.01, sale['TipAmount']
    Pos::DejavooTerminalPayment.call(@checkout)
    assert_equal 1, spin_sales, 'a paid checkout never goes to the terminal again'
    stored = PosPaymentAttempt.all.map(&:attributes).to_json + @checkout.attributes.to_json
    ['4111', 'PAT CARDHOLDER', 'card-token-secret', 'CUSTOMER COPY'].each { |secret| assert_not_includes stored, secret }
  end

  test 'a decline or cancel on the terminal allows a fresh attempt with a new reference' do
    @spin_sale_mode = :declined
    Pos::DejavooTerminalPayment.call(@checkout)
    assert_equal 'declined', @checkout.reload.status
    assert_equal Pos::DejavooTerminalPayment::DECLINED, attempt.decline_reason
    @spin_sale_mode = :canceled
    Pos::DejavooTerminalPayment.call(@checkout)
    assert_equal Pos::DejavooTerminalPayment::CANCELED, attempt.reload.decline_reason
    @spin_sale_mode = :approved
    Pos::DejavooTerminalPayment.call(@checkout)
    assert @checkout.reload.paid?
    assert_equal 3, spin_sales
    assert_equal 3, @spin_requests.map { |_, body| body['ReferenceId'] }.uniq.size
  end

  test 'an offline terminal charges nothing and says so' do
    @spin_sale_mode = :offline
    Pos::DejavooTerminalPayment.call(@checkout)
    assert_equal 'declined', @checkout.reload.status
    assert_equal Pos::DejavooTerminalPayment::TERMINAL_UNAVAILABLE, attempt.decline_reason
  end

  test 'a lost response stays unknown, blocks a second sale and is recovered from Status' do
    @spin_during_sale = -> { @spin_transactions['pending'] = true }
    @spin_sale_mode = :timeout
    assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    assert_equal 'unknown', @checkout.reload.status
    # The terminal did approve it before the response was lost.
    @spin_transactions[attempt.invoice] = { code: '0000', voided: false, total: '11.66' }
    Pos::DejavooTerminalPayment.call(@checkout)
    assert_equal 1, spin_sales, 'an unknown payment never triggers another sale'
    Pos::CardPayment.reconcile!(attempt)
    assert @checkout.reload.paid?
    assert_equal 1, spin_sales
  end

  test 'the background sweep leaves a sale alone while the terminal may still be waiting' do
    @spin_during_sale = lambda do
      Pos::DejavooTerminalPayment.reconcile!(attempt)
      assert_equal 'submitting', attempt.reload.status
      assert_equal 'processing', @checkout.reload.status
    end
    Pos::DejavooTerminalPayment.call(@checkout)
    assert @checkout.reload.paid?
    assert_equal ['v2/Payment/Sale'], spin_paths
  end

  test 'a SPIn timeout status is unknown, not a decline' do
    @spin_sale_mode = :timed_out
    assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    assert_equal 'unknown', @checkout.reload.status
    assert_equal 'unknown', attempt.status
  end

  test 'status recovery retries as debit when the sale was debit' do
    @spin_sale_mode = :timeout
    assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    @spin_transactions[attempt.invoice] = { code: '0000', voided: false, total: '11.66' }
    @spin_status_mode = :debit
    Pos::DejavooTerminalPayment.reconcile!(attempt)
    assert @checkout.reload.paid?
    assert_equal %w[Credit Debit], @spin_requests.select { |path, _| path == 'v2/Payment/Status' }.map { |_, body| body['PaymentType'] }
  end

  test 'not found right away is not proof; after the wait it is' do
    @spin_sale_mode = :timeout
    assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    assert_match(/not reported this payment yet/, assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.reconcile!(attempt) }.message)
    assert_equal 'unknown', @checkout.reload.status
    travel 6.minutes do
      Pos::DejavooTerminalPayment.reconcile!(attempt)
    end
    assert_equal 'declined', @checkout.reload.status
    assert_equal 'declined', attempt.status
  end

  test 'an approval for a different amount (surcharge or terminal tip) is held for review' do
    @spin_total = '12.01'
    @spin_fee = '0.35'
    assert_match(/different amount/, assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }.message)
    assert_equal 'unknown', @checkout.reload.status
    assert_equal Pos::DeclineReason::REVIEW, attempt.decline_reason
    assert_not @checkout.paid?
  end

  test 'a partial approval is voided at once and nothing is charged' do
    @spin_sale_mode = :partial
    Pos::DejavooTerminalPayment.call(@checkout)
    assert_equal 'declined', @checkout.reload.status
    assert_equal Pos::DejavooTerminalPayment::PARTIAL_REVERSED, attempt.decline_reason
    path, void = @spin_requests.last
    assert_equal 'v2/Payment/Void', path
    assert_equal attempt.invoice, void['ReferenceId']
    assert_in_delta 5.0, void['Amount']
  end

  test 'a partial approval that cannot be voided needs a manager' do
    @spin_sale_mode = :partial
    @spin_void_mode = :declined
    assert_match(/could not be reversed/, assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }.message)
    assert_equal 'unknown', @checkout.reload.status
    assert_equal Pos::DeclineReason::REVIEW, attempt.decline_reason
  end

  test 'a sale already voided on the terminal resolves as nothing charged' do
    @spin_sale_mode = :timeout
    assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    @spin_transactions[attempt.invoice] = { code: '0000', voided: true, total: '11.66' }
    Pos::DejavooTerminalPayment.reconcile!(attempt)
    assert_equal 'declined', @checkout.reload.status
    assert_equal Pos::DejavooTerminalPayment::VOIDED, attempt.decline_reason
  end

  test 'an item the processor did not approve never reaches the terminal' do
    ProcessorCatalog.create!(processor: 'dejavoo_spin', enforced: true, approval_reference: 'Valmar approval (fixture)').entries.create!(kind: 'sku', value: 'HH-OTHER-1')
    error = assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    assert_match(/not on the Dejavoo terminal approved list/, error.message)
    assert_empty @spin_requests
    assert_equal 'ready', @checkout.reload.status
  end

  test 'a changed terminal setup or disabled card checkout stops before the terminal' do
    @setting.update!(credentials_json: { tpn: 'SBXTPN0002', auth_key: AUTH_KEY }.to_json)
    assert_raises(Pos::Error) { Pos::DejavooTerminalPayment.call(@checkout) }
    assert_empty @spin_requests
  end

  test 'the browser card path and the refund screen refuse Dejavoo checkouts' do
    assert_match(/Dejavoo terminal/, assert_raises(Pos::Error) { Pos::CardPayment.call(@checkout, nonce: 'token') }.message)
    Pos::DejavooTerminalPayment.call(@checkout)
    error = assert_raises(Pos::Error) { Pos::CardReversal.call(checkout: @checkout.reload, amount_cents: 100, reason: 'Customer return', user: @user) }
    assert_match(/on the terminal/, error.message)
  end

  test 'Dejavoo has its own processor-approved list' do
    assert_equal 'dejavoo_spin', Payments::ItemEligibility.processor_for_tender('card', 'dejavoo_spin')
    assert ProcessorCatalog.create!(processor: 'dejavoo_spin').persisted?
  end
end
