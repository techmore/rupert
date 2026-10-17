# frozen_string_literal: true

require 'test_helper'

class BankFeedSyncJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @connection = BankConnection.create!(access_token: 'access-private', item_id: 'item-private', sync_enabled: true,
      credentials_json: { client_id: 'client-private', secret: 'secret-private' }.to_json)
  end
  teardown { Current.reset }

  test 'scheduler enqueues only opted in active workspaces and arguments contain no secrets' do
    assert_enqueued_with(job: BankFeedSyncJob, args: [@tenant.id]) { BankFeedSyncJob.perform_now }
    assert_equal 1, enqueued_jobs.count
    assert_not_includes enqueued_jobs.inspect, 'private'
    clear_enqueued_jobs
    @connection.update!(sync_enabled: false)
    assert_no_enqueued_jobs { BankFeedSyncJob.perform_now }
    @connection.update!(sync_enabled: true)
    @tenant.update!(status: 'suspended')
    assert_no_enqueued_jobs { BankFeedSyncJob.perform_now }
  end

  test 'jobs restore tenant context and do not read disconnected or suspended workspaces' do
    BankFeed::Sync.expects(:call).never
    @connection.update!(sync_enabled: false)
    BankFeedSyncJob.perform_now(@tenant.id)
    @connection.update!(sync_enabled: true)
    @tenant.update!(status: 'suspended')
    BankFeedSyncJob.perform_now(@tenant.id)
    assert_equal @tenant.id, Current.tenant_id
  end

  test 'accounting refusal is displayed as a safe code without leaking source data' do
    BankFeed::Sync.expects(:call).raises(ReconciliationEvidence::Error, 'private bank document detail')
    BankFeedSyncJob.perform_now(@tenant.id)
    assert_equal 'REVIEW_REQUIRED', @connection.reload.last_error_code
    assert_nil @connection.cursor
  end
end
