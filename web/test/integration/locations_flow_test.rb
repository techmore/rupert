# frozen_string_literal: true

require "test_helper"

class LocationsFlowTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: "loc@example.com", password: "password123", role: "admin", tenant_id: @tenant.id)
    post login_path, params: { email: "loc@example.com", password: "password123" }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: "m11u0i-sb.myshopify.com", embedded: "1", host: "test-host" })
  end

  test "locations index lists synced locations with units" do
    location = Location.create!(source: "shopify", externalId: "loc-1", name: "Main Shop", kind: "RETAIL", tenant_id: @tenant.id)
    product = ShopifyProduct.create!(id: "prod-loc1", title: "Tea", tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(id: "var-loc", productId: product.id, title: "Tea", sku: "LOC-TEA", tenant_id: @tenant.id)
    InventoryLevel.create!(source: "shopify", locationId: location.id, shopifyVariantId: variant.id, quantity: 12, available: 10, tenant_id: @tenant.id)

    get_page locations_path
    assert_response :success
    assert_select "h1", /Locations/
    assert_select "td", /Main Shop/
    assert_select "td", /12/
  end

  test "add a manual location" do
    get_page new_location_path
    assert_response :success

    post locations_path, params: {
      location: { name: "Popup Booth", kind: "POPUP", timezone: "America/Chicago", active: "1" },
      shop: "m11u0i-sb.myshopify.com",
      embedded: "1",
    }
    follow_redirect!
    assert_response :success

    location = Location.find_by!(name: "Popup Booth")
    assert_equal "manual", location.source
    assert_equal "POPUP", location.kind
    assert location.active?
  end

  test "location show page lists stock at that location" do
    location = Location.create!(source: "shopify", externalId: "loc-2", name: "Warehouse", kind: "WAREHOUSE", tenant_id: @tenant.id)
    product = ShopifyProduct.create!(id: "prod-loc2", title: "Bottles", tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(id: "var-loc2", productId: product.id, title: "Bottles", sku: "BTL", tenant_id: @tenant.id)
    InventoryLevel.create!(source: "shopify", locationId: location.id, shopifyVariantId: variant.id, quantity: 40, available: 38, tenant_id: @tenant.id)

    get_page location_path(location)
    assert_response :success
    assert_select "h1", /Warehouse/
    assert_select "td", /BTL/
    assert_select "td", /40/
  end

  test "location with stock can't be removed" do
    location = Location.create!(source: "shopify", externalId: "loc-3", name: "Locked", tenant_id: @tenant.id)
    InventoryLevel.create!(source: "shopify", locationId: location.id, quantity: 5, available: 5, tenant_id: @tenant.id)

    delete location_path(location), params: { shop: "m11u0i-sb.myshopify.com", embedded: "1" }
    follow_redirect!
    assert_response :success
    assert Location.exists?(location.id)
  end
end
