# frozen_string_literal: true

require 'test_helper'
require_relative '../support/nmi_sandbox_fixture'

class PosSettlementReconciliationTest < ActionDispatch::IntegrationTest
  include NmiSandboxFixture

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: 'settle-fixture/1', name: 'Settlement fixture')
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Front', opened_at: Time.current)
  end
  teardown { Current.reset }

  def paid_checkout(total, transaction_id, provider: 'authorize_net', environment: 'sandbox', tender: 'card')
    checkout = PosCheckout.create!(location: @location, user: @user, pos_display_session: @display, pos_session: @register, cart_revision: (@revision = @revision.to_i + 1),
      reference: SecureRandom.hex(16), tender: tender, status: 'paid', paid_at: 1.day.ago, lines_json: [], subtotal_cents: total, tax_cents: 0, tip_cents: 0,
      total_cents: total, gateway_id: tender == 'card' ? '123' : nil, environment: tender == 'card' ? environment : nil, gateway_provider: provider,
      gateway_fingerprint: tender == 'card' ? @setting.payment_fingerprint : nil)
    checkout.pos_payment_attempts.create!(invoice: "RP#{transaction_id}", nonce_digest: SecureRandom.hex(32), submitted_at: 1.day.ago, status: 'paid', transaction_id: transaction_id) if transaction_id
    checkout
  end

  test 'Authorize.net batches are matched to Rupert sales and refunds and exceptions are named' do
    @setting = PosSetting.create!(location: @location, gateway_id: '123', credentials_json: { api_login_id: 'l', transaction_key: 'k' }.to_json)
    @setting.update_columns(verified_at: Time.current)
    paid_checkout(1000, '901')                     # matched
    refunded = paid_checkout(2000, '902')          # matched, with a matched refund
    PosCardReversal.create!(pos_checkout: refunded, pos_payment_attempt: refunded.pos_payment_attempts.first, kind: 'refund', status: 'succeeded',
      reference: 'RVfix1', amount_cents: 500, transaction_id: '950', reason: 'Return', requested_by: @user, submitted_at: 1.day.ago)
    paid_checkout(3000, '903')                     # amount differs at gateway
    paid_checkout(4000, '904')                     # not settled yet
    paid_checkout(5000, '905')                     # voided at gateway only
    paid_checkout(1234, nil, tender: 'card_a920')  # standalone terminal sale
    stub_request(:post, Pos::Gateway::ENDPOINTS.fetch('sandbox')).to_return do |request|
      doc = JSON.parse(request.body)
      method = doc.keys.first
      data = case method
      when 'getMerchantDetailsRequest' then { gatewayId: '123', currencies: ['USD'], publicClientKey: 'p', isTestMode: false }
      when 'getSettledBatchListRequest'
        assert_equal true, doc.dig(method, 'includeStatistics')
        { batchList: [{ batchId: '777', settlementTimeUTC: '2026-11-01T22:00:00Z', statistics: [{ accountType: 'Visa', chargeAmount: 72.34, chargeCount: 4, refundAmount: 5.0, refundCount: 1 }] }] }
      when 'getTransactionListRequest'
        rows = [{ transId: '901', invoiceNumber: 'RP901', transactionStatus: 'settledSuccessfully', settleAmount: 10.0 },
          { transId: '902', invoiceNumber: 'RP902', transactionStatus: 'settledSuccessfully', settleAmount: 20.0 },
          { transId: '950', invoiceNumber: 'RVfix1', transactionStatus: 'refundSettledSuccessfully', settleAmount: 5.0 },
          { transId: '903', invoiceNumber: 'RP903', transactionStatus: 'settledSuccessfully', settleAmount: 29.99 },
          { transId: '960', invoiceNumber: '', transactionStatus: 'settledSuccessfully', settleAmount: 12.34 },
          { transId: '961', invoiceNumber: '', transactionStatus: 'declined', settleAmount: 0 }]
        { totalNumInResultSet: rows.size, transactions: rows }
      when 'getTransactionDetailsRequest'
        status = { '904' => 'capturedPendingSettlement', '905' => 'voided' }.fetch(doc.dig(method, 'transId'))
        { transaction: { transId: doc.dig(method, 'transId'), transactionStatus: status } }
      else flunk "Unexpected #{method}"
      end
      { status: 200, body: data.merge(messages: { resultCode: 'Ok' }).to_json }
    end
    report = Pos::SettlementReconciliation.call(setting: @setting, from: 3.days.ago, to: Time.current)
    by_id = report.rows.index_by(&:transaction_id)
    assert_equal 'matched', by_id['901'].status
    assert_equal %w[matched refund], [by_id['950'].status, by_id['950'].kind]
    assert_equal [2999, 3000, 'amount_mismatch'], [by_id['903'].gateway_cents, by_id['903'].rupert_cents, by_id['903'].status]
    assert_equal 'not_from_rupert', by_id['960'].status
    assert_nil by_id['961']
    assert_equal 'awaiting_settlement', by_id['904'].status
    assert_equal 'reversed_at_gateway', by_id['905'].status
    assert_equal 1234, report.terminal_cents
    assert_equal 1234, report.sum('not_from_rupert')
    assert_equal [7234, 500, 5], report.batches.first.to_h.values_at(:charge_cents, :refund_cents, :count)
    assert_not report.balanced?
    assert_not_requested :post, Pos::Gateway::ENDPOINTS.fetch('sandbox'), body: /createTransactionRequest/

    post login_path, params: { email: @user.email, password: 'password' }
    get pos_settlement_path(@location.id, run: '1', from: 3.days.ago.to_date.iso8601, to: Date.current.iso8601)
    assert_response :success
    assert_select 'h2', /Differences to review/
    assert_select 'span', /Amount differs/
  end

  test 'NMI settled transactions are read from settle actions' do
    @setting = PosSetting.create!(location: @location, gateway_provider: 'nmi', gateway_id: '123', credentials_json: nmi_credentials)
    @setting.update_columns(verified_at: Time.current)
    paid_checkout(1166, '12345', provider: 'nmi')
    prepare_nmi_fixture
    @nmi_invoice = 'RP12345'
    @nmi_xml_override = '<nm_response><transaction><transaction_id>12345</transaction_id><transaction_type>cc</transaction_type><condition>complete</condition>' \
      '<order_id>RP12345</order_id><currency>USD</currency><action><action_type>sale</action_type><success>1</success><amount>11.66</amount></action>' \
      '<action><action_type>settle</action_type><success>1</success><amount>11.66</amount><batch_id>555</batch_id><date>20261102030000</date></action></transaction>' \
      '<transaction><transaction_id>22222</transaction_id><transaction_type>cc</transaction_type><condition>complete</condition><order_id></order_id><currency>USD</currency>' \
      '<action><action_type>sale</action_type><success>1</success><amount>40.00</amount></action>' \
      '<action><action_type>settle</action_type><success>1</success><amount>40.00</amount><batch_id>555</batch_id></action></transaction></nm_response>'
    report = Pos::SettlementReconciliation.call(setting: @setting, from: 3.days.ago, to: Time.current)
    assert_equal %w[matched not_from_rupert], report.rows.sort_by(&:transaction_id).map(&:status)
    assert_equal [5166, 2], report.batches.first.to_h.values_at(:charge_cents, :count)
    assert report.balanced?
  end

  test 'window is limited' do
    @setting = PosSetting.create!(location: @location, gateway_id: '123')
    assert_raises(Pos::Error) { Pos::SettlementReconciliation.call(setting: @setting, from: 40.days.ago, to: Time.current) }
  end
end
