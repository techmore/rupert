# frozen_string_literal: true

require "test_helper"

class BusinessSettingsTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: "m11u0i-sb.myshopify.com",
        access_token: "test-token",
        is_online: false,
        expires: Time.now + 3600,
      )
    end
  end

  ShopifyApp::TokenExchange.prepend(TestShopifySession)

  setup do
    ShopifyAPI::Context.setup(
      api_key: "test-key",
      api_secret_key: "test-secret",
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: "localhost",
      scope: "read_products",
      is_private: false,
      is_embedded: false,
    )
    Shop.create!(shopify_domain: "m11u0i-sb.myshopify.com", shopify_token: "test-token")

    @tenant = Tenant.create!(name: "Test Co", subdomain: "testco")
    @user = User.create!(email: "biz@example.com", password: "password123", role: "admin", tenant_id: @tenant.id)
    post login_path, params: { email: "biz@example.com", password: "password123" }
    Current.tenant = @tenant

    @customer = Core::Customer.create!(tenant_id: @tenant.id, source: "shopify", external_id: "biz-1", first_name: "Ada")
    @order = Core::Order.new(
      source: "shopify",
      source_order_id: "biz-order-1",
      channel: "online",
      gross_cents: 2000,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      customer_id: @customer.id,
      order_number: "B-1",
      shipping_name: "Ada",
      shipping_address1: "1 Ln",
    )
    @order.mark_paid!
    @order.save!
    @order.order_lines.create!(tenant_id: @tenant.id, sku: "TEA", name: "Tea", quantity: 1, unit_cents: 2000, line_cents: 2000)
  end

  teardown do
    Setting.where("key LIKE ?", "tenant_%").delete_all
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1", host: "test-host" })
  end

  test "save business settings and see them on the invoice" do
    post tenant_settings_path, params: {
      business_name: "Herbal Healers CBD",
      invoice_prefix: "INV",
      low_stock_threshold: "3",
      shop: "m11u0i-sb.myshopify.com",
      embedded: "1",
    }
    follow_redirect!
    assert_response :success

    assert_equal "Herbal Healers CBD", TenantSettings.business_name
    assert_equal "INV", TenantSettings.invoice_prefix
    assert_equal 3, TenantSettings.low_stock_threshold_int

    get_page order_path(@order)
    assert_response :success
    assert_select "p", /Herbal Healers CBD/
    assert_select "h2", /INV-B-1/
  end

  test "low stock threshold feeds the alert generator" do
    TenantSettings.set(:low_stock_threshold, 3)
    Current.tenant = @tenant
    assert_equal 3, AlertGenerator.threshold_for_current_tenant
  end

  test "batch print renders packing slips for the day" do
    get_page sales_print_path(date: @order.occurred_at.to_date)
    assert_response :success
    assert_select "h1", /Print packing slips/
    assert_select "h2", /Order B-1/
    assert_select "td", /Tea/

    get_page sales_print_path(date: @order.occurred_at.to_date, doc: "invoice")
    assert_response :success
    assert_select "h1", /Print invoices/
    assert_select "h2", /INV-B-1/
    assert_select "td", /20\.00/
  end
end
