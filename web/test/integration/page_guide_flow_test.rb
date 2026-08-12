# frozen_string_literal: true

require "test_helper"

class PageGuideFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = User.create!(email: "pg-admin@example.com", password: "password123", role: "admin", name: "Admin", tenant_id: @tenant.id)
    post login_path, params: { email: @admin.email, password: "password123" }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  test "module pages render the how-to guide" do
    get inventory_index_path
    assert_response :success
    assert_includes response.body, "How to use this page"
    assert_includes response.body, "Drift"

    get sales_path
    assert_includes response.body, "How to use this page"
    assert_includes response.body, "source toggle"
  end

  test "pages without a guide don't show one" do
    order = Core::Order.create!(source: "shopify", source_order_id: "x1", occurred_at: Time.current,
      order_number: "X1", gross_cents: 1000, tenant_id: @tenant.id)
    get order_path(order)
    assert_response :success
    assert_not_includes response.body, "How to use this page"
  end
end
