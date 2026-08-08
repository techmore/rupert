# frozen_string_literal: true

require "test_helper"

# Smoke tests for the Oatmeal GUI: each page renders with a stubbed
# shop session.
class PagesFlowTest < ActionDispatch::IntegrationTest
  module TestShopifySession
    def current_shopify_session
      @test_session ||= ShopifyAPI::Auth::Session.new(
        shop: "m11u0i-sb.myshopify.com", access_token: "test-token",
        is_online: false, expires: Time.now + 3600
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
      is_embedded: false
    )
    Shop.create!(shopify_domain: "m11u0i-sb.myshopify.com", shopify_token: "test-token")
    post login_path, params: { email: "admin@example.com", password: "password" }
  end

  def get_page(path, params: {})
    get path, params: params.merge(shop: "m11u0i-sb.myshopify.com", embedded: "1", host: "test-host")
  end

  test "dashboard renders" do
    get_page "/"
    assert_response :success
    assert_select "h1", /Good morning/
  end

  test "inventory renders" do
    get_page inventory_index_path
    assert_response :success
    assert_select "h1", "Inventory"
  end

  test "reconcile renders with policy form" do
    get_page reconcile_index_path
    assert_response :success
    assert_select "h1", "Reconcile"
    if ShopifyVariant.exists?
      assert_select "select[name=priority]"
    else
      assert_select "td", /No SKU links yet/
    end
  end

  test "ledger renders" do
    get_page ledger_index_path
    assert_response :success
    assert_select "h1", "Ledger"
  end

  test "alerts renders" do
    get_page alerts_path
    assert_response :success
    assert_select "h1", "Alerts"
  end

  test "syncs renders" do
    get_page syncs_path
    assert_response :success
    assert_select "h1", "Sync"
  end

  test "settings renders" do
    get_page settings_path
    assert_response :success
    assert_select "h1", "Settings"
  end

  test "settings env json" do
    get_page env_settings_path
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.key?("keys")
  end

  test "env import and export round trip" do
    post env_import_settings_path, params: { text: "SQUARE_ENVIRONMENT=sandbox\n" }
    assert_response :success
    assert_equal ["SQUARE_ENVIRONMENT"], JSON.parse(response.body)["imported"]

    get env_export_settings_path
    assert_match(/SQUARE_ENVIRONMENT=sandbox/, response.body)

    Setting.find_by(key: "SQUARE_ENVIRONMENT").destroy
  end
end
