# frozen_string_literal: true

require "test_helper"

class ReportsFlowTest < ActionDispatch::IntegrationTest
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
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    EnvStore.set("SHOPIFY_CLIENT_ID", "test-client-id")
    EnvStore.set("SHOPIFY_CLIENT_SECRET", "test-client-secret")
    post login_path, params: { email: "admin@example.com", password: "password" }

    @loc = Location.create!(source: "square", externalId: "loc1", name: "Main Shop", tenant_id: @tenant.id)
    order = Core::Order.new(
      source: "square",
      source_order_id: "sq-1",
      channel: "pos",
      gross_cents: 2500,
      tax_cents: 200,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      location_id: @loc.externalId,
    )
    order.mark_paid!
    order.save!
    order.order_lines.create!(tenant_id: @tenant.id, sku: "OIL-1", name: "CBD Oil", quantity: 1, line_cents: 2500)
    order.payments.create!(tenant_id: @tenant.id, method: "card", amount_cents: 2500, status: "completed", paid_at: Time.current)

    ShopifyVariant.create!(
      title: "Oil",
      sku: "OIL-1",
      productId: "p1",
      price: 25.0,
      inventoryQuantity: 3,
      tenant_id: @tenant.id,
    )
    ShopifyProduct.create!(id: "p1", title: "CBD", tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
    EnvStore.set("SHOPIFY_CLIENT_ID", nil)
    EnvStore.set("SHOPIFY_CLIENT_SECRET", nil)
  end

  test "sales report renders charts and top products" do
    get sales_reports_path
    assert_response :success
    assert_select "h1", /Sales report/
    assert_select "td", /CBD Oil/
  end

  test "financial report renders P&L and tenders" do
    get financial_reports_path
    assert_response :success
    assert_select "h1", /Financial report/
    assert_select "td", /Net revenue/
    assert_select "td", /Gross revenue/
    assert_select "td", /Tax collected/
  end

  test "inventory report renders valuation and low stock" do
    get inventory_reports_path
    assert_response :success
    assert_select "h1", /Inventory report/
    assert_select "td", /OIL-1/
  end

  test "operations report renders" do
    get operations_reports_path
    assert_response :success
    assert_select "h1", /Operations report/
  end

  test "reports export CSV" do
    get sales_reports_path(format: :csv)
    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Day"
    assert_includes response.body, "Revenue"
  end

  test "readers can view reports" do
    User.create!(
      email: "reporter@example.com",
      password: "password123",
      role: "reader",
      tenant: tenants(:default_tenant),
    )
    delete logout_path
    post login_path, params: { email: "reporter@example.com", password: "password123" }

    get sales_reports_path
    assert_response :success
  end
end
