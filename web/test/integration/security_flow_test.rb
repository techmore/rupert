# frozen_string_literal: true

require "test_helper"

class SecurityFlowTest < ActionDispatch::IntegrationTest
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
    @reader = User.create!(email: "reader@example.com", password: "password123", role: "reader", tenant_id: @tenant.id, name: "Reader")
    post login_path, params: { email: "reader@example.com", password: "password123" }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1", host: "test-host" })
  end

  test "a reader cannot export environment secrets" do
    Setting.create!(key: "SHOPIFY_CLIENT_SECRET", tenant_id: @tenant.id, value: "super-secret-token")
    get_page env_export_settings_path
    # reader has no settings.read -> Pundit denies -> redirect
    assert_redirected_to(root_path)
    get env_export_settings_path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_not_includes response.body, "super-secret-token"
  end

  test "an admin with settings access cannot export environment secrets" do
    admin = User.create!(email: "admin2@example.com", password: "password123", role: "admin",
      tenant_id: @tenant.id, name: "Admin")
    Setting.create!(key: "SHOPIFY_CLIENT_SECRET", tenant_id: @tenant.id, value: "super-secret-token")

    delete logout_path
    post login_path, params: { email: "admin2@example.com", password: "password123" }
    get env_export_settings_path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_redirected_to(settings_path)
    assert_not_includes response.body, "super-secret-token"
  end

  test "a super admin can export environment secrets" do
    super_admin = User.create!(email: "boss@example.com", password: "password123", role: "super_admin",
      tenant_id: @tenant.id, name: "Boss")
    Setting.create!(key: "SHOPIFY_CLIENT_SECRET", tenant_id: @tenant.id, value: "super-secret-token")

    delete logout_path
    host! "#{@tenant.subdomain}.example.com"
    post login_path, params: { email: "boss@example.com", password: "password123" }
    get env_export_settings_path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_response :success
    assert_includes response.body, "super-secret-token"
  end

  test "a reader cannot download the database backup" do
    get_page backup_settings_path
    assert_redirected_to(root_path)
  end

  test "a reader cannot trigger a Google Drive backup" do
    EnvStore.set("GOOGLE_DRIVE_CLIENT_ID", "client-id")
    EnvStore.set("GOOGLE_DRIVE_CLIENT_SECRET", "client-secret")
    EnvStore.set("GOOGLE_DRIVE_REFRESH_TOKEN", "refresh-token")
    GoogleDriveBackupService.expects(:backup!).never

    post drive_backup_settings_path
    assert_redirected_to(root_path)
  end

  test "a reader cannot update settings or run syncs" do
    post tenant_settings_path, params: { business_name: "Hacked", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_redirected_to(root_path)
    assert_equal "Herbal Healers", TenantSettings.business_name

    post syncs_path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_redirected_to(root_path)
  end

  test "a reader cannot update alert status" do
    alert = StockAlert.create!(tenant_id: @tenant.id, sku: "X-1", quantity: 1, threshold: 5, status: "open")
    post update_status_alerts_path, params: { id: alert.id, status: "resolved", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_redirected_to(root_path)
    assert_equal "open", alert.reload.status
  end

  test "a reader cannot modify warehouse shares or tiers" do
    post warehouse_shares_path, params: { name: "Evil", priceMultiplier: "0", shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_redirected_to(root_path)
    assert_nil WarehouseShare.find_by(name: "Evil")

    post update_warehouse_tiers_path, params: { tiers: { "1" => { minQty: "1", discountPercent: "99" } }, shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    assert_redirected_to(root_path)
  end

  test "a reader can read inventory, ledger, and alerts but not settings" do
    get_page inventory_index_path
    assert_response :success
    get_page ledger_index_path
    assert_response :success
    get_page alerts_path
    assert_response :success
    get_page settings_path
    assert_redirected_to(root_path)
  end
end
