# frozen_string_literal: true

require "test_helper"

class DashboardCustomizeTest < ActionDispatch::IntegrationTest
  setup do
    ShopifyAPI::Context.setup(
      api_key: "test-key",
      api_secret_key: "test-secret",
      api_version: ShopifyAPI::AdminVersions::SUPPORTED_ADMIN_VERSIONS.first,
      host_name: "localhost",
      scope: "read_products",
      is_private: false,
      is_embedded: false
    )
    Shop.create!(shopify_domain: "m11u0i-sb.myshopify.com", shopify_token: "test-token")
    Current.tenant = tenants(:default_tenant)
    EnvStore.set("SHOPIFY_CLIENT_ID", "test-client-id")
    EnvStore.set("SHOPIFY_CLIENT_SECRET", "test-client-secret")
    post login_path, params: { email: "admin@example.com", password: "password" }
    @user = users(:regular_user)
    @user.update!(dashboard_config: nil)
  end

  teardown do
    Current.tenant = nil
    EnvStore.set("SHOPIFY_CLIENT_ID", nil)
    EnvStore.set("SHOPIFY_CLIENT_SECRET", nil)
  end

  test "dashboard renders all default widgets" do
    get dashboard_path
    assert_response :success
    DashboardWidget.default_order.each do |key|
      assert_select "[data-widget-key=#{key}]"
    end
  end

  test "customize saves layout and hides widgets" do
    post customize_dashboard_path, params: { widgets: %w[stats revenue sync_history],
      hidden: ["sync_history"] }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]

    @user.reload
    assert_equal "sync_history", @user.dashboard_config_hash["hidden"].first

    get dashboard_path
    assert_response :success
    assert_select "[data-widget-key=sync_history][hidden]"
    assert_select "[data-widget-key=stats]:not([hidden])"
  end

  test "customize rejects unknown widgets" do
    post customize_dashboard_path, params: { widgets: ["bogus"] }
    assert_response :unprocessable_entity
    assert_equal false, JSON.parse(response.body)["ok"]
  end

  test "reset clears the saved layout" do
    @user.update!(dashboard_config: { "widgets" => %w[revenue], "hidden" => [] })
    post customize_dashboard_path, params: { reset: true }
    assert_response :success

    @user.reload
    assert_nil @user.dashboard_config
    assert_equal DashboardWidget.default_order, DashboardWidget.entries(@user.dashboard_config_hash).map { |w, _| w.key }
  end
end
