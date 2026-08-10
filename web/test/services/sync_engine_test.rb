# frozen_string_literal: true

require "test_helper"

class SyncEngineTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    SyncRun.delete_all
    Current.tenant = nil
  end

  test "stale running syncs are failed before a new sync starts" do
    stale = SyncRun.create!(
      mode: "scheduled",
      status: "running",
      source: "all",
      startedAt: 46.minutes.ago,
    )

    assert_nothing_raised { SyncEngine.send(:guard_running!) }

    stale.reload
    assert_predicate stale, :failed?
    assert_not_nil stale.finishedAt
    assert_includes stale.error, "Automatically recovered stale sync"
  end

  test "a recent running sync still blocks overlap" do
    SyncRun.create!(
      mode: "scheduled",
      status: "running",
      source: "all",
      startedAt: 5.minutes.ago,
    )

    assert_raises(SyncEngine::AlreadyRunning) { SyncEngine.send(:guard_running!) }
  end
end
