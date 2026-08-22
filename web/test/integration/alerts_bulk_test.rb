# frozen_string_literal: true

require 'test_helper'

class AlertsBulkTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: 'alerts@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id)
    post login_path, params: { email: 'alerts@example.com', password: 'password123' }
    Current.tenant = @tenant

    @alerts = [
      StockAlert.create!(tenant_id: @tenant.id, sku: 'A-1', quantity: 2, threshold: 5, status: 'open'),
      StockAlert.create!(tenant_id: @tenant.id, sku: 'A-2', quantity: 0, threshold: 5, status: 'open'),
      StockAlert.create!(tenant_id: @tenant.id, sku: 'A-3', quantity: 4, threshold: 5, status: 'open')
    ]
  end

  teardown do
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'bulk resolve updates selected alerts' do
    get_page alerts_path
    assert_response :success
    assert_select "input[type=checkbox][name='alert_ids[]']", count: 3

    post bulk_update_alerts_path, params: {
      alert_ids: [@alerts[0].id, @alerts[1].id],
      status: 'resolved',
      tab: 'open',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    assert_equal 'resolved', @alerts[0].reload.status
    assert_equal 'resolved', @alerts[1].reload.status
    assert_equal 'open', @alerts[2].reload.status
    assert_not_nil @alerts[0].reload.resolvedAt
  end

  test 'bulk ignore updates selected alerts' do
    post bulk_update_alerts_path, params: {
      alert_ids: [@alerts[0].id, @alerts[1].id, @alerts[2].id],
      status: 'ignored',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success

    assert_equal 'ignored', @alerts[0].reload.status
    assert_equal 'ignored', @alerts[2].reload.status
  end

  test 'bulk with no selection is a no-op' do
    post bulk_update_alerts_path, params: {
      alert_ids: [],
      status: 'resolved',
      shop: 'm11u0i-sb.myshopify.com',
      embedded: '1'
    }
    follow_redirect!
    assert_response :success
    assert_equal 'open', @alerts[0].reload.status
  end
end
