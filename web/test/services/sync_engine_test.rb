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

  test "a Square-only sync is blocked while Square is frozen" do
    assert PlatformPushGuard.frozen?("square")

    SquareClient.stubs(:configured?).returns(true)
    error = assert_raises(PlatformPushGuard::FrozenError) do
      SyncEngine.run_source!("square", actor: "user")
    end
    assert_includes error.message, "FROZEN"
  end

  test "a full sync skips Square and records it while Square is frozen" do
    assert PlatformPushGuard.frozen?("square")

    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).never
    ShopifyClient.stubs(:graphql).returns({ "shop" => {}, "products" => { "nodes" => [] }, "locations" => { "nodes" => [] }, "orders" => { "nodes" => [] } })
    SquareSyncer.stubs(:primary_location_id).returns(nil)

    run = SyncEngine.run!(mode: "manual", actor: "user")

    assert_predicate run, :success?
    details = JSON.parse(run.details)
    assert_equal "skipped", details.dig("square", "status")
    assert_includes details.dig("square", "reason"), "frozen"
  end

  test "a frozen Square still blocks outbound writes" do
    assert PlatformPushGuard.frozen?("square")
    error = assert_raises(PlatformPushGuard::FrozenError) do
      PlatformPushGuard.authorize!("square", actor: "user")
    end
    assert_includes error.message, "FROZEN"
  end

  test "Current.sync_run is set for the duration of a sync and reset after" do
    PlatformPushGuard.unfreeze!("square", actor: "tester@example.com")
    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).returns({ items: [], variations: [], levels: [], links: [], orders: [], locations: [] })
    captured = nil
    LedgerImporter.stubs(:from_square_orders!).with { |_orders| captured = Current.sync_run_id; true }.returns(nil)

    run = SyncEngine.run_source!("square", actor: "user")

    assert_equal run.id, captured
    assert_nil Current.sync_run_id
  end
end
