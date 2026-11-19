# frozen_string_literal: true

require 'test_helper'

# Live Authorize.net SANDBOX acceptance for F69 (opt-in; skipped in CI).
#
#   AUTHORIZE_NET_SANDBOX_LOGIN_ID=... AUTHORIZE_NET_SANDBOX_TRANSACTION_KEY=... \
#     bin/rails test test/sandbox/authorize_net_sandbox_acceptance_test.rb
#
# Uses Rupert's own payment services against apitest.authorize.net only. Card
# tokens come from Authorize.net's sandbox securePaymentContainerRequest with
# Authorize.net's published test cards, standing in for Accept.js in the
# browser. Never point this at production credentials; the host is fixed.
class AuthorizeNetSandboxAcceptanceTest < ActiveSupport::TestCase
  SANDBOX = Pos::Gateway::ENDPOINTS.fetch('sandbox')

  setup do
    @login = ENV.fetch('AUTHORIZE_NET_SANDBOX_LOGIN_ID', '')
    @key = ENV.fetch('AUTHORIZE_NET_SANDBOX_TRANSACTION_KEY', '')
    skip 'Set AUTHORIZE_NET_SANDBOX_LOGIN_ID and AUTHORIZE_NET_SANDBOX_TRANSACTION_KEY to run the live sandbox acceptance.' if @login.empty? || @key.empty?

    WebMock.disable_net_connect!(allow: URI(SANDBOX).host)
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @location = Location.create!(source: 'ctrax', externalId: "anet-sandbox/#{SecureRandom.hex(3)}", name: 'Authorize.net sandbox')
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Sandbox', opened_at: Time.current)
    gateway_id = raw('getMerchantDetailsRequest').fetch('gatewayId').to_s
    @setting = PosSetting.create!(location: @location, gateway_id: gateway_id, environment: 'sandbox',
      credentials_json: { api_login_id: @login, transaction_key: @key }.to_json)
    @merchant = Pos::Gateway.new(@setting).merchant
    @setting.update!(verified_at: Time.current, public_client_key: @merchant.fetch('publicClientKey'))
    @setting.update!(card_enabled: true)
  end

  teardown do
    WebMock.disable_net_connect!
    Current.reset
  end

  # Raw sandbox call used only for setup and test-card tokens.
  def raw(method, **fields)
    uri = URI(SANDBOX)
    response = Net::HTTP.post(uri, JSON.generate(method => { merchantAuthentication: { name: @login, transactionKey: @key } }.merge(fields)), 'Content-Type' => 'application/json')
    doc = JSON.parse(response.body.b.delete_prefix("\xEF\xBB\xBF".b).force_encoding('UTF-8'))
    assert_equal 'Ok', doc.dig('messages', 'resultCode'), doc.dig('messages', 'message', 0, 'text')
    doc
  end

  def token(card = '4111111111111111')
    raw('securePaymentContainerRequest', refId: 'rupert', data: { type: 'TOKEN', id: SecureRandom.uuid,
      token: { cardNumber: card, expirationDate: "12#{Date.current.year + 3}", cardCode: '900' } }).fetch('opaqueData').fetch('dataValue')
  end

  def checkout(total_cents, lines = [{ 'variant_id' => 'sandbox-1', 'sku' => 'HH-CBD-TINC', 'category' => 'CBD Tinctures', 'title' => 'CBD tincture', 'quantity' => 1 }])
    display = PosDisplaySession.create!(user: @user, location: @location)
    lines = lines.map { |line| line.merge('unit_price' => format('%.2f', total_cents / 100.0), 'line_total' => format('%.2f', total_cents / 100.0)) }
    PosCheckout.create!(location: @location, user: @user, pos_display_session: display, pos_session: @register, cart_revision: 1,
      reference: SecureRandom.hex(16), tender: 'card', lines_json: lines, subtotal_cents: total_cents, tax_cents: 0, tip_cents: 0,
      total_cents: total_cents, gateway_id: @setting.gateway_id, environment: 'sandbox', gateway_fingerprint: @setting.payment_fingerprint)
  end

  # Unique amounts keep the gateway's duplicate-transaction window out of the way.
  def amount = 1_000 + SecureRandom.random_number(8_000)

  test 'live sandbox: approve, receipt, void, decline, eligibility, recovery, online charge and settlement read' do
    log = []

    # 1. Approved charge through Rupert's POS card path.
    sale = checkout(amount)
    Pos::CardPayment.call(sale, nonce: token)
    sale.reload
    assert sale.paid?, "expected paid, got #{sale.status}"
    card = sale.receipt[:card]
    assert_equal '1111', card[:last_four]
    assert card[:auth_code].present?
    assert_equal sale.total_cents, sale.order.payments.sum(:amount_cents)
    log << "approved #{card[:transaction_id]} #{card[:brand]} ending #{card[:last_four]} auth #{card[:auth_code]}"

    # 2. Read-only recovery by invoice alone finds the same charge (lost-response path).
    attempt = sale.pos_payment_attempts.first
    found = Pos::Gateway.new(@setting).tap(&:merchant).detail(attempt.transaction_id)
    assert_equal attempt.invoice, found.dig('order', 'invoiceNumber')

    # 3. Partial void refused; full void succeeds and records a refund on the sale.
    assert_raises(Pos::Error) { Pos::CardReversal.call(checkout: sale, amount_cents: 100, reason: 'Sandbox partial', user: @user) }
    void = Pos::CardReversal.call(checkout: sale.reload, amount_cents: sale.total_cents, reason: 'Sandbox void', user: @user)
    assert_equal %w[void succeeded], [void.kind, void.status]
    assert_equal 'voided', Pos::Gateway.new(@setting).tap(&:merchant).detail(attempt.transaction_id)['transactionStatus']
    assert sale.order.reload.fully_refunded?
    log << "voided #{attempt.transaction_id}"

    # 4. Decline: sandbox test card 4222222222222 declines with reason code = amount in dollars (2 = declined).
    declined = checkout(200)
    Pos::CardPayment.call(declined, nonce: token('4222222222222'))
    assert_equal 'declined', declined.reload.status
    assert_equal Pos::DeclineReason::ISSUER, declined.receipt[:decline_reason]
    assert_empty Core::Order.where(source_order_id: declined.reference)
    log << "declined: #{declined.receipt[:decline_reason]}"

    # 5. Processor approved list: an unapproved SKU is refused before any charge.
    catalog = ProcessorCatalog.create!(processor: 'authorize_net', enforced: true, approval_reference: 'Sandbox acceptance')
    catalog.entries.create!(kind: 'category', value: 'CBD Tinctures')
    blocked = checkout(amount, [{ 'variant_id' => 'sandbox-2', 'sku' => 'HH-THCA-FLOWER', 'category' => 'THCA Flower', 'title' => 'THCA flower', 'quantity' => 1 }])
    error = assert_raises(Pos::Error) { Pos::CardPayment.call(blocked, nonce: token) }
    assert_match(/not on the Authorize.net approved list/, error.message)
    assert_empty blocked.pos_payment_attempts
    log << 'eligibility block: no request sent'

    # 6. Online checkout client (warehouse/web path) charges with the same token type.
    snapshot = { sandbox: true, login_id: @login, transaction_key: @key }
    online = AuthorizeNetClient.charge!(amount_cents: amount, payment_nonce: token, ref_id: "wh-#{SecureRandom.hex(4)}",
      invoice_number: "WH#{SecureRandom.hex(6)}", description: 'Rupert sandbox online', credential_snapshot: snapshot)
    assert online.approved?, "online charge not approved: #{online.message}"
    log << "online approved #{online.transaction_id}"

    # 7. Settlement read for the last two days parses real batch data (sandbox
    #    settles once a day, so today's charges are not in a batch yet).
    report = Pos::SettlementReconciliation.call(setting: @setting, from: 2.days.ago, to: Time.current)
    log << "settlement: #{report.batches.size} batches, #{report.rows.size} rows, #{report.count('not_from_rupert')} not from Rupert"

    puts "\nAuthorize.net sandbox acceptance (gateway #{@setting.gateway_id}):\n  #{log.join("\n  ")}"
  end
end
