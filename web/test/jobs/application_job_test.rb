# frozen_string_literal: true

require 'test_helper'

class ApplicationJobTest < ActiveJob::TestCase
  class ReadLocationJob < ApplicationJob
    def perform(tenant_id, seen)
      Current.set(tenant: Tenant.find(tenant_id)) { seen << EnvStore.fetch('SQUARE_LOCATION_ID', '') }
    end
  end

  teardown { Current.reset }

  test 'a credential changed between two job runs is seen by the second run' do
    tenant = tenants(:default_tenant)
    Setting.find_or_create_for('SQUARE_LOCATION_ID', tenant.id) { |row| row.value = 'L-OLD' }
    seen = []
    ReadLocationJob.perform_now(tenant.id, seen)
    # Another process (the settings page, a different worker) rewrites the row directly.
    Setting.for_tenant('SQUARE_LOCATION_ID', tenant.id).update!(value: 'L-NEW')
    ReadLocationJob.perform_now(tenant.id, seen)
    assert_equal %w[L-OLD L-NEW], seen
  end

  test 'jobs that used to bypass ApplicationJob now inherit its hooks' do
    [DataRetentionJob, DailyReconciliationArchiveJob, AppScopesUpdateJob].each do |job|
      assert_operator job, :<, ApplicationJob
    end
  end
end
