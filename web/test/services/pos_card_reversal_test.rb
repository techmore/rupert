# frozen_string_literal: true

require 'test_helper'
require_relative '../support/nmi_sandbox_fixture'

# Authorize.net: receipt details, decline reasons, void and refund.
class PosCardReversalTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'reversal-fixture/1', name: 'Reversal fixture')
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_id: '123', credentials_json: { api_login_id: 'fixture-login', transaction_key: 'fixture-key' }.to_json)
    @setting.update!(verified_at: Time.current, public_client_key: 'fixture-public')
    @setting.update!(card_enabled: true)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register,
      cart_revision: 1, reference: SecureRandom.hex(16), tender: 'card', lines_json: [{ 'variant_id' => '7', 'title' => 'CBD tincture', 'quantity' => 1, 'unit_price' => '10.05', 'line_total' => '10.05' }],
      subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166, gateway_id: '123', environment: 'sandbox')
    @status = 'capturedPendingSettlement'
    @charge_mode = :approved
    @reversal_mode = :approved
    @requests = Hash.new(0)
    @refunds = {}
    stub_request(:post, Pos::Gateway::ENDPOINTS.fetch('sandbox')).to_return do |request|
      doc = JSON.parse(request.body)
      method = doc.keys.first
      @requests[method] += 1
      body = doc[method]
      data = case method
      when 'getMerchantDetailsRequest'
        { gatewayId: '123', currencies: ['USD'], publicClientKey: 'fixture-public', isTestMode: false }
      when 'createTransactionRequest'
        tx = body['transactionRequest']
        case tx['transactionType']
        when 'authCaptureTransaction'
          @invoice = tx.dig('order', 'invoiceNumber')
          if @charge_mode == :declined
            { transactionResponse: { responseCode: '2', transId: '0', errors: [{ errorCode: '44', errorText: 'raw vendor text 4111' }] } }
          else
            { transactionResponse: { responseCode: '1', transId: '900', authCode: 'AB12CD', accountNumber: 'XXXX1111', accountType: 'Visa' } }
          end
        when 'voidTransaction'
          assert_equal '900', tx['refTransId']
          assert_equal %w[transactionType refTransId], tx.keys
          @status = 'voided' unless @reversal_mode == :not_applied
          raise Net::ReadTimeout if %i[timeout not_applied].include?(@reversal_mode)
          { transactionResponse: { responseCode: '1', transId: '900' } }
        when 'refundTransaction'
          assert_equal %w[transactionType amount payment refTransId order], tx.keys
          assert_equal({ 'cardNumber' => '1111', 'expirationDate' => 'XXXX' }, tx.dig('payment', 'creditCard'))
          id = "95#{@refunds.size}"
          @refunds[tx.dig('order', 'invoiceNumber')] = { transId: id, amount: tx['amount'] } unless @reversal_mode == :declined
          raise Net::ReadTimeout if @reversal_mode == :timeout
          next_response = @reversal_mode == :declined ? { responseCode: '3', transId: '0', errors: [{ errorCode: '54' }] } : { responseCode: '1', transId: id }
          { transactionResponse: next_response }
        end
      when 'getTransactionDetailsRequest'
        id = body['transId']
        refund = @refunds.find { |_ref, row| row[:transId] == id }
        if refund
          { transaction: { transId: id, transactionType: 'refundTransaction', transactionStatus: 'refundPendingSettlement', responseCode: '1', authAmount: refund.last[:amount], refTransId: '900', order: { invoiceNumber: refund.first } } }
        else
          { transaction: { transId: '900', transactionType: 'authCaptureTransaction', transactionStatus: @status, responseCode: '1', authAmount: '11.66', authCode: 'AB12CD',
            payment: { creditCard: { cardNumber: 'XXXX1111', cardType: 'Visa' } }, order: { invoiceNumber: @invoice } } }
        end
      when 'getUnsettledTransactionListRequest'
        rows = [{ transId: '900', invoiceNumber: @invoice }] + @refunds.map { |ref, row| { transId: row[:transId], invoiceNumber: ref } }
        { totalNumInResultSet: rows.size, transactions: rows }
      when 'getSettledBatchListRequest'
        { batchList: [] }
      else flunk "Unexpected gateway method #{method}"
      end
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: data.merge(messages: { resultCode: 'Ok' }).to_json }
    end
  end
  teardown { Current.reset }

  def pay! = Pos::CardPayment.call(@checkout, nonce: "token-#{SecureRandom.hex(4)}")

  def reverse!(cents, reason = 'Customer returned item') = Pos::CardReversal.call(checkout: @checkout.reload, amount_cents: cents, reason: reason, user: @user)

  test 'paid receipt carries brand, last four and approval code from verified details, never a card number' do
    pay!
    receipt = @checkout.reload.receipt
    assert_equal({ processor: 'Authorize.net', brand: 'Visa', last_four: '1111', auth_code: 'AB12CD', transaction_id: '900', refunded_cents: 0 }, receipt[:card])
    assert_not_includes PosPaymentAttempt.first.attributes.to_json, '4111'
  end

  test 'decline stores a cashier-safe reason, never gateway text' do
    @charge_mode = :declined
    pay!
    assert_equal 'declined', @checkout.reload.status
    assert_equal Pos::DeclineReason::CVV, @checkout.receipt[:decline_reason]
    assert_not_includes PosPaymentAttempt.first.attributes.to_json, 'raw vendor text'
  end

  test 'unsettled payment voids the whole sale only and records a refund on the order' do
    pay!
    error = assert_raises(Pos::Error) { reverse!(500) }
    assert_match(/only the whole sale can be voided/, error.message)
    assert_empty PosCardReversal.all
    reversal = reverse!(1166)
    assert_equal %w[void succeeded], [reversal.kind, reversal.status]
    order = @checkout.reload.order
    assert_equal 1166, order.refunds.sum(:amount_cents)
    assert order.fully_refunded?
    assert_equal 'void-900', reversal.core_refund.reference
    assert_raises(Pos::Error) { reverse!(1) }
    assert_equal 1, @requests['createTransactionRequest'] - 1
  end

  test 'settled payment refunds part then the rest; over-refunds are refused before any request' do
    pay!
    @status = 'settledSuccessfully'
    first = reverse!(500)
    assert_equal %w[refund succeeded 950], [first.kind, first.status, first.transaction_id]
    assert_raises(Pos::Error) { reverse!(667) }
    second = reverse!(666)
    assert_equal 'succeeded', second.status
    assert_equal 1166, @checkout.reload.receipt[:card][:refunded_cents]
    assert @checkout.order.reload.fully_refunded?
    assert_equal 3, @requests['createTransactionRequest']
  end

  test 'refused refund records a reason and leaves the sale untouched' do
    pay!
    @status = 'settledSuccessfully'
    @reversal_mode = :declined
    reversal = reverse!(500)
    assert_equal 'failed', reversal.status
    assert_match(/can no longer be refunded/, reversal.failure_message)
    assert_empty @checkout.reload.order.refunds
  end

  test 'lost refund response stays unknown, blocks another refund and is settled by a read-only recheck' do
    pay!
    @status = 'settledSuccessfully'
    @reversal_mode = :timeout
    assert_raises(Pos::Error) { reverse!(500) }
    reversal = PosCardReversal.last
    assert_equal 'unknown', reversal.status
    assert_empty @checkout.reload.order.refunds
    @reversal_mode = :approved
    assert_raises(Pos::Error) { reverse!(100) }
    sent = @requests['createTransactionRequest']
    Pos::CardReversal.reconcile!(reversal)
    assert_equal 'succeeded', reversal.reload.status
    assert_equal sent, @requests['createTransactionRequest']
    assert_equal 500, @checkout.order.reload.refunds.sum(:amount_cents)
  end

  test 'lost void response is confirmed from the original charge status' do
    pay!
    @reversal_mode = :timeout
    assert_raises(Pos::Error) { reverse!(1166) }
    reversal = PosCardReversal.last
    Pos::CardReversal.reconcile!(reversal)
    assert_equal 'succeeded', reversal.reload.status
  end

  test 'a void that never reached the gateway is recorded as failed so it can be tried again' do
    pay!
    @reversal_mode = :not_applied
    assert_raises(Pos::Error) { reverse!(1166) }
    reversal = PosCardReversal.last
    Pos::CardReversal.reconcile!(reversal)
    assert_equal 'failed', reversal.reload.status
    @reversal_mode = :approved
    assert_equal 'succeeded', reverse!(1166).status
  end

  test 'refunds need a verified paid gateway payment in this workspace' do
    assert_raises(Pos::Error) { reverse!(100) }
    pay!
    Current.tenant = Tenant.create!(name: 'Other', subdomain: 'other-reversal', status: 'active')
    assert_raises(Pos::Error) { Pos::CardReversal.call(checkout: @checkout, amount_cents: 100, reason: 'wrong shop', user: @user) }
  end
end

# NMI: production after owner sign-off, receipts, void and refund.
class PosNmiProductionTest < ActiveSupport::TestCase
  include NmiSandboxFixture
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'nmi-prod-fixture/1', name: 'NMI production fixture')
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'nmi', gateway_id: '123', environment: 'production', credentials_json: nmi_credentials,
      production_approved_at: Time.current, production_approved_by: @user, production_approval_note: 'Backup ISO approval email 2026-11-20')
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register,
      cart_revision: 1, reference: SecureRandom.hex(16), tender: 'card', gateway_provider: 'nmi',
      gateway_fingerprint: @setting.payment_fingerprint, gateway_id: '123', environment: 'production',
      lines_json: [{ 'variant_id' => '7', 'title' => 'CBD tincture', 'quantity' => 1, 'unit_price' => '10.05', 'line_total' => '10.05' }],
      subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166)
    prepare_nmi_fixture(environment: 'production')
  end
  teardown { Current.reset }

  test 'signed-off production sale creates a real order, register total and receipt details' do
    Pos::CardPayment.call(@checkout, nonce: 'prod-token-approved')
    assert @checkout.reload.paid?
    assert_not @checkout.sandbox_payment?
    assert_equal 1166, @checkout.order.payments.sum(:amount_cents)
    assert_equal 1166, @register.reload.card_sales_cents
    assert_equal({ processor: 'NMI', brand: 'Visa', last_four: '1111', auth_code: '123456', transaction_id: '12345', refunded_cents: 0 }, @checkout.receipt[:card])
    assert_not_requested :post, Pos::NmiGateway.transact_url('sandbox')
  end

  test 'decline keeps a mapped reason' do
    @nmi_mode = :declined
    Pos::CardPayment.call(@checkout, nonce: 'prod-token-declined')
    assert_equal Pos::DeclineReason::FUNDS, @checkout.reload.receipt[:decline_reason]
  end

  test 'void before settlement and refund after settlement' do
    Pos::CardPayment.call(@checkout, nonce: 'prod-token-void')
    void = Pos::CardReversal.call(checkout: @checkout.reload, amount_cents: 1166, reason: 'Rang up twice', user: @user)
    assert_equal %w[void succeeded], [void.kind, void.status]
    assert_equal 'void', @nmi_reversals.last['type']
    assert @checkout.order.reload.fully_refunded?
  end

  test 'partial refund after settlement, and a lost refund response is confirmed from NMI actions' do
    Pos::CardPayment.call(@checkout, nonce: 'prod-token-refund')
    @nmi_condition = 'complete'
    first = Pos::CardReversal.call(checkout: @checkout.reload, amount_cents: 300, reason: 'Partial return', user: @user)
    assert_equal %w[refund succeeded 12399], [first.kind, first.status, first.transaction_id]
    assert_equal '3.00', @nmi_reversals.last['amount']
    @nmi_reversal_mode = :timeout
    assert_raises(Pos::Error) { Pos::CardReversal.call(checkout: @checkout.reload, amount_cents: 300, reason: 'Second return', user: @user) }
    second = PosCardReversal.last
    assert_equal 'unknown', second.status
    Pos::CardReversal.reconcile!(second)
    assert_equal 'succeeded', second.reload.status
    assert_equal 600, @checkout.order.reload.refunds.sum(:amount_cents)
    assert_equal 2, @nmi_reversals.size
  end

  test 'refused NMI refund is recorded as failed' do
    Pos::CardPayment.call(@checkout, nonce: 'prod-token-refused')
    @nmi_condition = 'complete'
    @nmi_reversal_mode = :declined
    reversal = Pos::CardReversal.call(checkout: @checkout.reload, amount_cents: 300, reason: 'Return', user: @user)
    assert_equal 'failed', reversal.status
    assert_empty @checkout.order.reload.refunds
  end
end
