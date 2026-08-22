# frozen_string_literal: true

require 'test_helper'

class WarehouseCartFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: 'm11u0i-sb.myshopify.com',
        access_token: 'test-token',
        is_online: false,
        expires: Time.now + 3600
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: 'test-key',
      api_secret_key: 'test-secret',
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: 'localhost',
      scope: 'read_products',
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: 'm11u0i-sb.myshopify.com', shopify_token: 'test-token')

    @tenant = Tenant.create!(name: 'Ware Co', subdomain: 'wareco')
    Current.tenant = @tenant

    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', 'testlogin')
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', 'testtxnkey')
    EnvStore.set('AUTHORIZE_NET_SANDBOX', '1')

    @share = WarehouseShare.create!(name: 'Sage Supply', priceMultiplier: 0.8, tenant: @tenant)
    @location = Location.create!(source: 'shopify', externalId: 'loc-1', name: 'Main Shop', tenant_id: @tenant.id)
    @product = ShopifyProduct.create!(id: 'prod-cart', title: 'Tea', status: 'ACTIVE', tenant_id: @tenant.id)
    @variant = ShopifyVariant.create!(
      id: 'var-cart',
      productId: @product.id,
      title: '100g',
      price: 20.0,
      sku: 'TEA-100',
      tracked: true,
      tenant_id: @tenant.id
    )
    InventoryLevel.create!(
      source: 'shopify',
      locationId: @location.id,
      shopifyVariantId: @variant.id,
      quantity: 50,
      available: 50,
      tenant_id: @tenant.id
    )

    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200, body: approved_gateway_body, headers: { 'Content-Type' => 'application/json' })
  end

  teardown do
    EnvStore.set('AUTHORIZE_NET_LOGIN_ID', nil)
    EnvStore.set('AUTHORIZE_NET_TRANSACTION_KEY', nil)
    EnvStore.set('AUTHORIZE_NET_SANDBOX', nil)
    Current.tenant = nil
  end

  def approved_gateway_body
    {
      transactionResponse: {
        responseCode: '1',
        transId: '40001234',
        authCode: 'OK',
        messages: { code: '1', description: 'This transaction has been approved.' }
      }
    }.to_json
  end

  test 'add to cart, update quantities, and see server-priced totals' do
    get warehouse_sale_path(@share.token)
    assert_response :success
    assert_select 'a.btn-primary', /View cart/

    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    assert_redirected_to warehouse_cart_path(@share.token)
    follow_redirect!
    assert_response :success
    assert_select 'p', /Tea · 100g/
    assert_select 'p', /Total \$80\.00/

    cart = WarehouseCart.last
    assert_equal 5, cart.items.sum(:quantity)
    # 20.00 list × 0.8 multiplier = 16.00/unit; no tiers → 80.00.
    assert_equal 16_00, cart.items.first.unit_cents
    assert_equal 80_00, cart.items.first.line_cents

    patch warehouse_cart_item_path(@share.token, cart.items.first.id), params: { quantity: '10' }
    follow_redirect!
    cart.items.first.reload
    assert_equal 10, cart.items.first.quantity
    assert_equal 160_00, cart.items.first.line_cents
  end

  test 'checkout creates a paid canonical order and checks out the cart' do
    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '5' }
    cart = WarehouseCart.last

    get warehouse_checkout_path(@share.token)
    assert_response :success
    assert_select 'h1', /Checkout/
    assert_select '#accept-card-number'

    orders_before = Core::Order.unscoped.count
    assert_difference 'Core::Payment.unscoped.count' do
      post warehouse_checkout_submit_path(@share.token), params: {
        shipping_name: 'Ada Vendor',
        shipping_address1: '1 Main St',
        shipping_city: 'Springfield',
        shipping_zip: '12345',
        shipping_country: 'US',
        payment_nonce: 'payment-nonce-1',
        data_descriptor: 'COMMON.ACCEPT.INAPP.PAYMENT'
      }
    end

    assert_redirected_to(%r{/w/#{@share.token}/orders/})
    assert_equal orders_before + 1, Core::Order.unscoped.count
    follow_redirect!
    assert_response :success
    assert_select 'h1', /Order confirmed/

    order = Core::Order.unscoped.last
    assert_equal 'warehouse', order.channel
    assert_equal 80_00, order.gross_cents
    assert order.paid?
    assert_equal 1, order.order_lines.count
    assert_equal 16_00, order.order_lines.first.unit_cents
    assert_equal '40001234', order.payments.first.reference
    assert_equal 'Ada Vendor', order.shipping_name
    assert_equal 5, order.line_items

    assert cart.reload.checked_out?
  end

  test 'declined payment leaves no paid order' do
    stub_request(:post, 'https://apitest.authorize.net/xml/v1/request.api')
      .to_return(status: 200,
                 body: {
                   transactionResponse: {
                     responseCode: '2',
                     messages: { code: '2', description: 'This transaction has been declined.' }
                   }
                 }.to_json,
                 headers: { 'Content-Type' => 'application/json' })

    post warehouse_cart_add_item_path(@share.token), params: { variant_id: @variant.id, quantity: '2' }
    cart = WarehouseCart.last
    paid_before = Core::Order.unscoped.where(status: 'paid').count

    assert_no_difference 'Core::OrderLine.unscoped.count' do
      post warehouse_checkout_submit_path(@share.token), params: {
        shipping_name: 'Ada',
        shipping_address1: '1 Main',
        shipping_city: 'Springfield',
        shipping_zip: '12345',
        shipping_country: 'US',
        payment_nonce: 'bad-nonce'
      }
    end

    assert_response :unprocessable_entity
    assert_select "div[role='alert']", /declined/

    assert_equal paid_before, Core::Order.unscoped.where(status: 'paid').count
    refute cart.reload.checked_out?
  end

  test 'empty cart cannot reach checkout' do
    get warehouse_checkout_path(@share.token)
    assert_response :not_found
  end
end
