# frozen_string_literal: true

require 'test_helper'

class SyncWatchTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    EnvStore.set('SHOPIFY_CLIENT_ID', 'configured')
    EnvStore.set('SQUARE_ACCESS_TOKEN', 'configured')
  end

  teardown do
    Current.reset
    RequestStore.clear!
  end

  test 'each configured source must have a fresh watermark' do
    Setting.find_or_create_for('sync_watermark_shopify', @tenant.id) { |s| s.value = 2.minutes.ago.iso8601 }
    Setting.find_or_create_for('sync_watermark_square', @tenant.id) { |s| s.value = 2.hours.ago.iso8601 }
    assert_equal ['square'], SyncWatch.failures.map { |failure| failure[:source] }
    Setting.find_or_create_for('sync_watermark_square', @tenant.id) { |s| s.value = 1.minute.ago.iso8601 }
    assert_empty SyncWatch.failures
  end

  test 'disabled integrations are not expected' do
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SQUARE_ACCESS_TOKEN', nil)
    assert_empty SyncWatch.failures
  end

  test 'another tenant cannot mask stale or absent acquisition evidence' do
    other = Tenant.create!(name: 'Other', subdomain: 'other-watch', status: 'active')
    Setting.find_or_create_for('sync_watermark_shopify', @tenant.id) { |s| s.value = 1.minute.ago.iso8601 }
    Setting.find_or_create_for('sync_watermark_square', @tenant.id) { |s| s.value = 1.minute.ago.iso8601 }
    Current.set(tenant: other) { EnvStore.set('SHOPIFY_CLIENT_ID', 'configured') }
    failures = SyncWatch.failures
    assert_equal [[other.id, 'shopify']], failures.map { |entry| entry.values_at(:tenant_id, :source) }
  end

  test 'a failed enabled source channel is reported independently of a healthy catalog' do
    EnvStore.set('SHOPIFY_CLIENT_ID', nil)
    EnvStore.set('SQUARE_ACCESS_TOKEN', nil)
    Ctrax::Client.stubs(:valid_credentials?).returns(true)
    PosConnection.create!(provider: 'ctrax', environment: 'production', vendor_approved: true,
      hourly_sync_enabled: true, reporting_enabled: false,
      credentials_json: { api_url: 'https://example.api.cannatrax.net', api_username: 'synthetic', api_password: 'synthetic' }.to_json)
    SyncAttempt.create!(source: 'ctrax', operation: 'stock', status: 'failed', error_category: 'network',
      queued_at: 1.minute.ago, started_at: 1.minute.ago, finished_at: 1.minute.ago)
    failures = SyncWatch.failures
    assert_includes failures.map { |entry| entry[:source] }, 'ctrax/stock'
    refute_includes failures.map { |entry| entry[:source] }, 'ctrax/sales'
  end
end
