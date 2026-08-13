# frozen_string_literal: true

require "test_helper"

class SearchFlowTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: "search@example.com", password: "password123", role: "admin", tenant_id: @tenant.id)
    post login_path, params: { email: "search@example.com", password: "password123" }
    Current.tenant = @tenant

    @customer = Core::Customer.create!(
      tenant_id: @tenant.id,
      source: "shopify",
      external_id: "search-1",
      first_name: "Zoe",
      last_name: "Bloom",
      email: "zoe@example.com",
    )
    @order = Core::Order.new(
      source: "shopify",
      source_order_id: "search-order-1",
      channel: "online",
      gross_cents: 2500,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      customer_id: @customer.id,
      order_number: "Z-7777",
    )
    @order.mark_paid!
    @order.save!
    @product = ShopifyProduct.create!(id: "prod-search", title: "Tea", tenant_id: @tenant.id)
    @variant = ShopifyVariant.create!(id: "var-search", productId: @product.id, title: "Green", sku: "GRN-SEARCH", tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
  end

  test "search endpoint returns orders, customers, and SKUs as JSON" do
    get search_path, params: { q: "Z-7777", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_response :success
    json = JSON.parse(response.body)
    order = json.find { |r| r["type"] == "order" }
    assert_equal "Z-7777", order["label"]
    assert_equal "/orders/#{@order.id}", order["path"]

    get search_path, params: { q: "zoe", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    json = JSON.parse(response.body)
    customer = json.find { |r| r["type"] == "customer" }
    assert_equal "Zoe Bloom", customer["label"]
    assert_equal "/customers/#{@customer.id}", customer["path"]

    get search_path, params: { q: "GRN-SEARCH", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    json = JSON.parse(response.body)
    sku = json.find { |r| r["type"] == "sku" }
    assert_equal "GRN-SEARCH", sku["label"]
    assert_equal "/shopify_variants/#{@variant.id}", sku["path"]
  end

  test "short search returns empty and shell renders search trigger" do
    get search_path, params: { q: "a", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_response :success
    assert_equal [], JSON.parse(response.body)

    get_page sales_path
    assert_select "button", /Search/
    assert_select "kbd", "/"
  end

  test "search returns employees for users with hr.read" do
    People::Employee.create!(tenant_id: @tenant.id, first_name: "Casey", last_name: "Adams", employee_number: "E-SRCH", email: "casey@example.com")

    get search_path, params: { q: "casey", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_response :success
    json = JSON.parse(response.body)
    employee = json.find { |r| r["type"] == "employee" }
    assert_equal "Casey Adams", employee["label"]
    assert_match %r{^/people/employees/\d+}, employee["path"]
  end

  test "employees are hidden from users without hr.read" do
    People::Employee.create!(tenant_id: @tenant.id, first_name: "Casey", last_name: "Adams", employee_number: "E-SRCH")
    User.create!(email: "cashier@example.com", password: "password123", role: "cashier", tenant_id: @tenant.id)
    delete logout_path
    post login_path, params: { email: "cashier@example.com", password: "password123" }

    get search_path, params: { q: "casey", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_response :success
    json = JSON.parse(response.body)
    refute json.any? { |r| r["type"] == "employee" }
  end

  test "search is tenant-scoped" do
    other = Tenant.create!(name: "Other", subdomain: "other")
    User.create!(email: "other@example.com", password: "password123", role: "admin", tenant_id: other.id)
    delete logout_path
    post login_path, params: { email: "other@example.com", password: "password123" }

    get search_path, params: { q: "Z-7777", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    json = JSON.parse(response.body)
    assert_empty json
  end

  private

  def get_page(path)
    get(path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1", host: "test-host" })
  end
end
