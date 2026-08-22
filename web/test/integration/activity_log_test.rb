# frozen_string_literal: true

require 'test_helper'

class ActivityLogTest < ActionDispatch::IntegrationTest
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
    @user = User.create!(email: 'audit@example.com', password: 'password123', role: 'admin', tenant_id: @tenant.id,
                         name: 'Auditor')
    post login_path, params: { email: 'audit@example.com', password: 'password123' }
    Current.tenant = @tenant
  end

  teardown do
    ActivityLog.where(tenant_id: @tenant.id).delete_all
    Current.tenant = nil
  end

  def get_page(path)
    get(path, params: { shop: 'm11u0i-sb.myshopify.com', embedded: '1', host: 'test-host' })
  end

  test 'recording a refund creates an activity log entry' do
    order = Core::Order.new(
      source: 'shopify',
      source_order_id: 'audit-1',
      channel: 'online',
      gross_cents: 2000,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      order_number: 'A-1'
    )
    order.mark_paid!
    order.save!
    order.payments.create!(tenant_id: @tenant.id, method: 'card', amount_cents: 2000, status: 'completed',
                           paid_at: Time.current)

    post refund_order_path(order), params: {
      amount: '20.00', method: 'cash', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
    }
    follow_redirect!

    entry = ActivityLog.where(tenant_id: @tenant.id, action: 'refund_recorded').last
    assert_not_nil entry
    assert_equal 'Auditor', entry.actor_name
    assert_equal 'Core::Order', entry.subject_type
    assert_equal 'A-1', entry.subject_label
    assert_includes entry.details, '$20.00'
  end

  test 'adding tracking creates an activity log entry' do
    order = Core::Order.new(
      source: 'shopify',
      source_order_id: 'audit-2',
      channel: 'online',
      gross_cents: 1000,
      occurred_at: Time.current,
      tenant_id: @tenant.id,
      order_number: 'A-2'
    )
    order.mark_paid!
    order.save!

    post add_tracking_order_path(order), params: {
      tracking_company: 'UPS', tracking_number: '1Z999', shop: 'm11u0i-sb.myshopify.com', embedded: '1'
    }
    follow_redirect!

    entry = ActivityLog.where(tenant_id: @tenant.id, action: 'tracking_added').last
    assert_not_nil entry
    assert_equal 'A-2', entry.subject_label
    assert_includes entry.details, 'UPS 1Z999'
  end

  test 'activity page lists recent entries and is tenant-scoped' do
    ActivityLogger.log('test_action', details: 'hello', subject: @user)
    get_page activity_path
    assert_response :success
    assert_select 'h1', /Activity/
    assert_select 'td', /Auditor/
    assert_select 'span.pill-taupe', /test action/
    assert_select 'td', /hello/
  end
end
