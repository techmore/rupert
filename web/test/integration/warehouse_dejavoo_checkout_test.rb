# frozen_string_literal: true

require 'test_helper'

# Online checkout through Dejavoo's Hosted Payment Page (sandbox stubs). The
# shopper pays on Dejavoo's page; Rupert confirms with queryPaymentStatus.
class WarehouseDejavooCheckoutTest < ActionDispatch::IntegrationTest
  AUTH = 'https://auth.ipospays.tech/v1/authenticate-token'
  CREATE = 'https://payment.ipospays.tech/api/v3/external-payment-transaction'
  STATUS = %r{\Ahttps://api\.ipospays\.tech/v1/queryPaymentStatus\?}
  PAGE = 'https://payment.ipospays.tech/api/v1/externalPay?t=hpp-link-token'
  TPN = '123456789012'
  KEYS = { 'DEJAVOO_HPP_TPN' => TPN, 'DEJAVOO_HPP_API_KEY' => 'sandbox-api-key-1', 'DEJAVOO_HPP_SECRET_KEY' => 'sandbox-secret-1',
           'DEJAVOO_HPP_ECOM_TOKEN' => 'sandbox-ecom-token-1' }.freeze

  setup do
    @tenant = Tenant.create!(name: 'Ware Co', subdomain: 'warehpp')
    Current.tenant = @tenant
    KEYS.each { |key, value| EnvStore.set(key, value) }
    Rails.cache.clear
    @share = WarehouseShare.create!(name: 'Sage Supply', priceMultiplier: 0.8, tenant: @tenant)
    @location = Location.create!(source: 'shopify', externalId: 'loc-hpp', name: 'Main Shop', tenant_id: @tenant.id)
    @product = ShopifyProduct.create!(id: 'prod-hpp', title: 'Tea', status: 'ACTIVE', tenant_id: @tenant.id)
    @variant = ShopifyVariant.create!(id: 'var-hpp', productId: @product.id, title: '100g', price: 20.0, sku: 'TEA-100', tracked: true, tenant_id: @tenant.id)
    InventoryLevel.create!(source: 'shopify', locationId: @location.id, shopifyVariantId: @variant.id, quantity: 50, available: 50, tenant_id: @tenant.id)
    @created = []
    @status = { responseCode: 200, responseMessage: 'Successful', totalAmount: '80.00' }
    stub_request(:post, AUTH).with(headers: { 'apiKey' => 'sandbox-api-key-1', 'secretKey' => 'sandbox-secret-1' })
      .to_return(status: 200, body: { responseCode: '00', responseMessage: 'Success', token: 'eyJhbGciOiJSUzI1NiJ9.sandbox.token' }.to_json)
    stub_request(:post, CREATE).with(headers: { 'token' => 'eyJhbGciOiJSUzI1NiJ9.sandbox.token' }).to_return do |request|
      @created << JSON.parse(request.body)
      { status: 200, body: { message: 'Url generated Successful', information: PAGE }.to_json }
    end
    stub_request(:get, STATUS).with(headers: { 'Authorization' => 'sandbox-ecom-token-1' }).to_return do |request|
      reference = Rack::Utils.parse_query(URI(request.uri.to_s).query)['transactionReferenceId']
      body = @status ? { iposHPResponse: @status.merge(transactionReferenceId: reference, transactionId: 'HPP-TX-1', cardType: 'VISA', cardLast4Digit: '1111', responseApprovalCode: 'TAS164') } : {}
      { status: 200, body: body.to_json }
    end
  end

  teardown do
    (KEYS.keys + %w[DEJAVOO_HPP_ENVIRONMENT DEJAVOO_HPP_PRODUCTION_SIGNOFF]).each { |key| EnvStore.set(key, nil) }
    Current.tenant = nil
  end

  def start_checkout
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    get warehouse_checkout_path(@share.token)
    assert_response :success
    post warehouse_checkout_submit_path(@share.token), params: { checkout_quote: WarehouseCheckoutQuote.issue(WarehouseCart.last),
      shipping_name: 'Ada Vendor', shipping_address1: '1 Main St', shipping_city: 'Springfield', shipping_zip: '12345', shipping_country: 'US' }
    WarehousePaymentAttempt.unscoped.last
  end

  test 'the checkout page has no card fields and sends the shopper to Dejavoo for the exact total' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    get warehouse_checkout_path(@share.token)
    assert_select '#accept-card-number', count: 0
    assert_includes response.body, 'Continue to secure payment'
    assert_match(/form-action 'self' https:\/\/payment\.ipospays\.tech/, response.headers['Content-Security-Policy'])
    post warehouse_checkout_submit_path(@share.token), params: { checkout_quote: WarehouseCheckoutQuote.issue(WarehouseCart.last),
      shipping_name: 'Ada Vendor', shipping_address1: '1 Main St', shipping_city: 'Springfield', shipping_zip: '12345', shipping_country: 'US' }
    attempt = WarehousePaymentAttempt.unscoped.last
    assert_redirected_to PAGE
    request = @created.last
    assert_equal TPN, request.dig('merchantAuthentication', 'merchantId')
    assert_equal attempt.invoice_number, request.dig('merchantAuthentication', 'transactionReferenceId')
    assert_equal '8000', request.dig('transactionRequest', 'amount')
    assert_equal [false, false, false], request['transactionRequest'].values_at('calculateFee', 'calculateTax', 'tipsInputPrompt')
    assert_includes request.dig('notificationOption', 'returnUrl'), "/w/#{@share.token}/checkout/dejavoo/#{attempt.invoice_number}"
    assert_equal %w[dejavoo_hpp submitting], [attempt.provider, attempt.status]
  end

  test 'returning from Dejavoo creates the paid order only after the server-side status check' do
    attempt = start_checkout
    # Dejavoo posts the browser back cross-site, without the cart cookie or a CSRF token.
    post warehouse_checkout_dejavoo_path(@share.token, attempt.invoice_number), params: { responseCode: '200', totalAmount: '0.01' }
    assert_response :see_other
    follow_redirect!
    assert_redirected_to(%r{/w/#{@share.token}/orders/})
    order = Core::Order.unscoped.last
    assert order.paid?
    assert_equal 80_00, order.gross_cents
    assert_equal 'HPP-TX-1', Core::Payment.unscoped.last.reference
    assert_equal 'paid', attempt.reload.status
  end

  test 'an approval for a different amount is held for review and never makes an order' do
    @status[:totalAmount] = '79.00'
    attempt = start_checkout
    get warehouse_checkout_dejavoo_path(@share.token, attempt.invoice_number)
    assert_equal 'unknown', attempt.reload.status
    assert_equal 0, Core::Order.unscoped.count
  end

  test 'a cancelled or declined payment releases the stock and allows a fresh try' do
    @status = { responseCode: 400, responseMessage: 'Cancelled By Customer' }
    attempt = start_checkout
    get warehouse_checkout_dejavoo_path(@share.token, attempt.invoice_number)
    assert_equal 'declined', attempt.reload.status
    assert attempt.warehouse_stock_holds.all? { |hold| hold.status == 'released' }
    @status = { responseCode: 200, responseMessage: 'Successful', totalAmount: '80.00' }
    second = start_checkout
    assert_not_equal attempt.id, second.id
    assert_redirected_to PAGE
  end

  test 'an unpaid page can be resumed instead of starting a second payment' do
    @status = nil
    attempt = start_checkout
    get warehouse_checkout_path(@share.token)
    assert_includes response.body, 'Continue to payment'
    assert_includes response.body, PAGE.split('?').first
    get warehouse_checkout_dejavoo_path(@share.token, attempt.invoice_number)
    assert_redirected_to warehouse_checkout_path(@share.token)
    assert_equal 'submitting', attempt.reload.status
    assert_equal 1, @created.size
  end

  test 'production stays off until the owner records sign-off' do
    EnvStore.set('DEJAVOO_HPP_ENVIRONMENT', 'production')
    assert_not DejavooHostedPage.configured?
    EnvStore.set('DEJAVOO_HPP_PRODUCTION_SIGNOFF', 'Valmar approved live online payments, 2026-11-20')
    assert DejavooHostedPage.configured?
  end
end
