# frozen_string_literal: true

require 'test_helper'

class BackupLogTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  test 'latest and latest_success find the newest matching record' do
    BackupLog.create!(status: 'failed', startedAt: 2.hours.ago, tenant_id: Current.tenant_id)
    ok = BackupLog.create!(status: 'success', startedAt: 1.hour.ago, tenant_id: Current.tenant_id)

    assert_equal ok.id, BackupLog.latest.id
    assert_equal ok.id, BackupLog.latest_success.id
  end

  test 'validates status and startedAt' do
    log = BackupLog.new(status: 'bogus', startedAt: Time.current)
    refute log.valid?
    assert_includes log.errors[:status], 'is not included in the list'

    log.status = 'running'
    assert log.valid?
  end
end
