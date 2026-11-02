# frozen_string_literal: true

require 'test_helper'
require_relative '../support/fake_square_loyalty'

class SquareLoyaltySyncJobTest < ActiveJob::TestCase
  include FakeSquareLoyalty

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    @tenant = Current.tenant
    SquareClient.stubs(:token).returns('synthetic-private-token')
    SquareClient.stubs(:environment).returns('production')
  end
  teardown { Current.reset }

  test 'the schedule is an explicit per-workspace opt-in and queues only tenant IDs' do
    assert_no_enqueued_jobs { SquareLoyaltySyncJob.perform_now }
    SquareLoyaltySync.configure!(enabled: true)
    assert_enqueued_with(job: SquareLoyaltySyncJob, args: [@tenant.id]) { SquareLoyaltySyncJob.perform_now }
    job = enqueued_jobs.find { |queued| queued[:job] == SquareLoyaltySyncJob }
    refute_includes job.inspect, 'synthetic-private-token'
    assert_equal 'queued', SyncAttempt.where(source: 'square', operation: 'loyalty').last.status
    SquareLoyaltySync.configure!(enabled: false)
    assert_no_enqueued_jobs { SquareLoyaltySyncJob.perform_now }
  end

  test 'a scheduled run mirrors loyalty and records a successful attempt; re-running adds nothing' do
    stub_square_loyalty(accounts: [fake_account('acct-1', customer_id: nil, balance: 9)],
      events: [[fake_event('ev-1', account: 'acct-1', type: 'ACCUMULATE_POINTS', at: '2026-10-30T10:00:00Z', points: 9)]])
    SquareLoyaltySync.configure!(enabled: true)
    SquareLoyaltySyncJob.perform_now(@tenant.id)
    assert_equal 'succeeded', SyncAttempt.where(source: 'square', operation: 'loyalty').order(:id).last.status
    assert_no_difference(['SquareLoyaltyAccount.count', 'SquareLoyaltyEvent.count']) { SquareLoyaltySyncJob.perform_now(@tenant.id) }
    assert_equal 1, SquareLoyaltyEvent.count
  end

  test 'an unconfigured workspace makes no Square request' do
    other = Tenant.create!(name: 'No loyalty', subdomain: 'no-loyalty')
    SquareClient.expects(:request).never
    SquareLoyaltySyncJob.perform_now(other.id)
  end

  test 'a failed run keeps the mirror and records a safe failure message' do
    stub_square_loyalty(scopes: %w[CUSTOMERS_READ])
    assert_raises(SquareLoyaltyReader::MissingScope) { SquareLoyaltySyncJob.perform_now(@tenant.id, actor_id: Current.user.id) }
    attempt = SyncAttempt.where(source: 'square', operation: 'loyalty').order(:id).last
    assert_equal %w[failed entitlement], [attempt.status, attempt.error_category]
    assert_includes SquareLoyaltySync.state['last_failure'], 'LOYALTY_READ'
    refute_includes SquareLoyaltySync.state.to_json, 'synthetic-private-token'
  end

  test 'a manual run needs someone allowed to sync' do
    reader = User.create!(tenant: @tenant, email: 'loyalty-job-reader@example.test', password: 'password123', role: 'reader')
    SquareClient.expects(:request).never
    assert_raises(Pundit::NotAuthorizedError) { SquareLoyaltySyncJob.perform_now(@tenant.id, actor_id: reader.id) }
  end
end
