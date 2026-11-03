# frozen_string_literal: true

require 'test_helper'
require 'openssl'

class PosWebhooksTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ANET_KEY = 'A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2'
  NMI_KEY = 'nmi-signing-key-fixture-0123456789'

  setup do
    Current.tenant = tenants(:default_tenant)
    @location = Location.create!(source: 'ctrax', externalId: 'webhook-fixture/1', name: 'Webhook fixture')
    @setting = PosSetting.create!(location: @location, gateway_id: '123', webhook_signing_key: ANET_KEY,
      credentials_json: { api_login_id: 'fixture-login', transaction_key: 'fixture-key' }.to_json)
  end
  teardown { Current.reset }

  def anet_post(body, key: ANET_KEY, setting: @setting)
    signature = OpenSSL::HMAC.hexdigest('SHA512', [key].pack('H*'), body).upcase
    post pos_webhook_path(setting.id), params: body, headers: { 'Content-Type' => 'application/json', 'X-ANET-Signature' => "sha512=#{signature}" }
  end

  def anet_event(id = '900')
    { notificationId: SecureRandom.uuid, eventType: 'net.authorize.payment.authcapture.created', eventDate: Time.current.iso8601,
      webhookId: SecureRandom.uuid, payload: { responseCode: 1, authAmount: 99_999.0, entityName: 'transaction', id: id } }.to_json
  end

  test 'signed Authorize.net event queues a read-only recheck with only the transaction id' do
    assert_enqueued_with(job: PosWebhookJob, args: [{ tenant_id: @setting.tenant_id, setting_id: @setting.id, transaction_id: '900', order_id: nil }]) do
      anet_post(anet_event)
    end
    assert_response :ok
  end

  test 'bad signature, missing key, unknown setting and oversized bodies are refused' do
    anet_post(anet_event, key: ANET_KEY.reverse)
    assert_response :unauthorized
    post pos_webhook_path(@setting.id), params: anet_event, headers: { 'Content-Type' => 'application/json' }
    assert_response :unauthorized
    @setting.update!(webhook_signing_key: nil)
    anet_post(anet_event)
    assert_response :not_found
    post pos_webhook_path(0), params: anet_event
    assert_response :not_found
    @setting.update!(webhook_signing_key: ANET_KEY)
    anet_post({ pad: 'x' * 70_000 }.to_json)
    assert_response :content_too_large
    assert_no_enqueued_jobs only: PosWebhookJob
  end

  test 'signed but irrelevant events are acknowledged without work' do
    anet_post({ eventType: 'net.authorize.customer.created', payload: { entityName: 'customerProfile', id: '5' } }.to_json)
    assert_response :ok
    assert_no_enqueued_jobs only: PosWebhookJob
  end

  test 'signed NMI event uses nonce.body HMAC-SHA256 and passes transaction and order ids' do
    @setting.update!(gateway_provider: 'nmi', credentials_json: '{}', webhook_signing_key: NMI_KEY)
    body = { event_id: SecureRandom.uuid, event_type: 'transaction.sale.success',
      event_body: { transaction_id: '12345', order_id: 'RNabc123', action: { amount: '99999.00', success: '1' } } }.to_json
    nonce = 'nonce-1700000000'
    signature = OpenSSL::HMAC.hexdigest('SHA256', NMI_KEY, "#{nonce}.#{body}")
    assert_enqueued_with(job: PosWebhookJob, args: [{ tenant_id: @setting.tenant_id, setting_id: @setting.id, transaction_id: '12345', order_id: 'RNabc123' }]) do
      post pos_webhook_path(@setting.id), params: body, headers: { 'Content-Type' => 'application/json', 'Webhook-Signature' => "t=#{nonce},s=#{signature}" }
    end
    assert_response :ok
    post pos_webhook_path(@setting.id), params: body, headers: { 'Content-Type' => 'application/json', 'Webhook-Signature' => "t=other,s=#{signature}" }
    assert_response :unauthorized
  end

  test 'webhook job rechecks an unknown payment through the gateway without charging' do
    user = users(:regular_user)
    display = PosDisplaySession.create!(user: user, location: @location)
    register = Sales::PosSession.create!(location: @location, user: user, name: 'Front', opened_at: Time.current)
    @setting.update!(verified_at: Time.current, public_client_key: 'fixture-public')
    checkout = PosCheckout.create!(location: @location, user: user, pos_display_session: display, pos_session: register, cart_revision: 1,
      reference: SecureRandom.hex(16), tender: 'card', status: 'unknown', lines_json: [], subtotal_cents: 1000, tax_cents: 0, tip_cents: 0, total_cents: 1000,
      gateway_id: '123', environment: 'sandbox')
    attempt = checkout.pos_payment_attempts.create!(invoice: 'RPwebhook1', nonce_digest: 'd' * 64, submitted_at: 5.minutes.ago, status: 'unknown', transaction_id: '900')
    stub_request(:post, Pos::Gateway::ENDPOINTS.fetch('sandbox')).to_return do |request|
      method = JSON.parse(request.body).keys.first
      data = case method
      when 'getMerchantDetailsRequest' then { gatewayId: '123', currencies: ['USD'], publicClientKey: 'fixture-public', isTestMode: false }
      when 'getTransactionDetailsRequest'
        { transaction: { transId: '900', transactionType: 'authCaptureTransaction', transactionStatus: 'capturedPendingSettlement', responseCode: '1', authAmount: '10.00',
          authCode: 'XY1', payment: { creditCard: { cardNumber: 'XXXX4242', cardType: 'Visa' } }, order: { invoiceNumber: 'RPwebhook1' } } }
      else flunk "Unexpected #{method}"
      end
      { status: 200, body: data.merge(messages: { resultCode: 'Ok' }).to_json }
    end
    PosWebhookJob.perform_now(tenant_id: @setting.tenant_id, setting_id: @setting.id, transaction_id: '900', order_id: nil)
    assert checkout.reload.paid?
    assert_equal %w[paid 4242], [attempt.reload.status, attempt.card_last_four]
  end
end
