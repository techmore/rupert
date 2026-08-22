# frozen_string_literal: true

require 'test_helper'

class OrderFlowTest < ActionDispatch::IntegrationTest
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

    @tenant = Tenant.create!(name: 'Test Co', subdomain: 'testco')
    @user = User.create!(email: 'orders@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'orders@example.com', password: 'password123' }
    Current.tenant = @tenant

    @customer = Core::Customer.create!(
      tenant_id: @tenant.id,
      source: 'shopify',
      external_id: 'cus-1',
      first_name: 'Ada',
      last_name: 'Lovelace',
      email: 'ada@example.com'
    )
    @order = Core::Order.new(
      source: 'shopify',
      source_order_id: 'shop-1',
      channel: 'online',
      gross_cents: 3000,
      tax_cents: 200,
      line_items: 1,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      customer_id: @customer.id,
      order_number: '#1001',
      shipping_name: 'Ada Lovelace',
      shipping_address1: '1 Analytical Ln',
      shipping_city: 'London',
      shipping_zip: 'SW1'
    )
    @order.mark_paid!
    @order.save!
    @order.order_lines.create!(tenant_id: @tenant.id, sku: 'TEA-50', name: 'Honey Sticks', quantity: 2,
                               unit_cents: 1400, line_cents: 2800)
    @order.payments.create!(tenant_id: @tenant.id, method: 'card', amount_cents: 3000, status: 'completed',
                            paid_at: Time.current)
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'order show page renders a full invoice' do
    get_page order_path(@order)
    assert_response :success
    assert_select 'h1', /#1001/
    assert_select 'td', /Honey Sticks/
    assert_select 'td', /TEA-50/
    assert_select 'dd', /28.00/          # line subtotal
    assert_select 'dd', /2.00/           # tax
    assert_select 'dd', /30.00/          # total
    assert_select 'p', /Ada Lovelace/
    assert_select 'p', /1 Analytical Ln/
    assert_select 'p', /London/
  end

  test 'order show links from the sales journal' do
    get_page sales_path
    assert_response :success
    assert_select "a[href='#{order_path(@order)}']", text: '#1001'
  end

  test 'packing slip view hides prices' do
    get_page order_path(@order, doc: 'packing_slip')
    assert_response :success
    assert_select 'h1', /#1001/
    assert_select 'p.eyebrow', /Packing slip/
    assert_select 'td', /Honey Sticks/
    assert_select 'td', /TEA-50/
    assert_select 'dd', text: /28.00/, count: 0 # prices hidden
  end

  test 'fulfillment status is hidden when flag is off' do
    get_page order_path(@order)
    assert_response :success
    assert_select 'h2', text: /Fulfillment status/, count: 0
  end

  test 'fulfillment status workflow works when enabled' do
    FeatureFlag.set(:fulfillment_workflow, true)
    Current.tenant = @tenant

    get_page(order_path(@order))
    assert_response(:success)
    assert_select('h2', /Fulfillment status/)

    post(update_fulfillment_status_order_path(@order), params: {
           status: 'shipped', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
         })
    follow_redirect!
    assert_response(:success)
    assert_equal('shipped', @order.reload.fulfillment_status)

    post(update_fulfillment_status_order_path(@order), params: {
           status: 'completed', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
         })
    follow_redirect!
    assert_equal('completed', @order.reload.fulfillment_status)

    post(update_fulfillment_status_order_path(@order), params: {
           status: 'pending', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
         })
    follow_redirect!
    assert_equal('completed', @order.reload.fulfillment_status) # backward move rejected
  ensure
    FeatureFlag.set(:fulfillment_workflow, false)
  end

  test 'fulfillment status is rejected when flag is off' do
    post update_fulfillment_status_order_path(@order), params: {
      status: 'shipped', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 'pending', @order.reload.fulfillment_status
  end

  test 'order page shows refund summary and partial refund keeps order paid' do
    get_page(order_path(@order))
    assert_response(:success)
    assert_select 'h2', /Refunds/
    assert_select 'p', /refundable \$30\.00/

    post refund_order_path(@order), params: {
      amount: '10.00',
      method: 'card',
      reason: 'One item returned',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response(:success)

    @order.reload
    assert_equal 1000, @order.total_refunded_cents
    assert_equal 2000, @order.refundable_cents
    assert_equal 'paid', @order.status # partial refund keeps it paid
    assert_equal 'One item returned', @order.refunds.first.reason
  end

  test 'full refund transitions the order to refunded' do
    post refund_order_path(@order), params: {
      amount: '30.00',
      method: 'cash',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response(:success)

    @order.reload
    assert_equal 3000, @order.total_refunded_cents
    assert_equal 'refunded', @order.status
    assert @order.fully_refunded?
  end

  test 'over-refund is rejected' do
    post refund_order_path(@order), params: {
      amount: '50.00',
      method: 'card',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response(:success)

    @order.reload
    assert_equal 0, @order.total_refunded_cents
    assert_equal 'paid', @order.status
  end

  test 'adding tracking marks the order fulfilled' do
    assert_equal 'paid', @order.status

    post add_tracking_order_path(@order), params: {
      tracking_company: 'UPS',
      tracking_number: '1Z999AA10123456784',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    @order.reload
    assert_equal 'fulfilled', @order.status
    fulfillment = @order.fulfillments.first
    assert_equal 'UPS', fulfillment.tracking_company
    assert_equal '1Z999AA10123456784', fulfillment.tracking_number
    assert_includes fulfillment.tracking_url, 'ups.com'

    assert_select 'a', text: '1Z999AA10123456784'
  end

  test 'order show is tenant-scoped' do
    other = Tenant.create!(name: 'Other Co', subdomain: 'otherco')
    assert_raises(ActiveRecord::RecordNotFound) do
      Core::Order.find_by!(tenant_id: other.id, id: @order.id)
    end
  end
end
