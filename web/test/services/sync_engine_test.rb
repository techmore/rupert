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
      startedAt: (SyncEngine::STALE_RUN_AFTER + 1.minute).ago,
    )

    SyncEngine.send(:recover_stale_runs!)

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

    assert_raises(SyncEngine::AlreadyRunning) do
      SyncEngine.send(:create_run!, mode: "scheduled", source: "all", actor: "user")
    end
  end
end
