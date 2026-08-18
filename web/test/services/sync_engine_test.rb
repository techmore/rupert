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

  test "run! proactively recovers an orphaned run so the schedule stays alive" do
    # A worker restart left an old run marked running (no details/error) —
    # run! must clear it before starting, not block for the whole window.
    orphan = SyncRun.create!(
      mode: "scheduled",
      status: "running",
      source: "all",
      startedAt: (SyncEngine::STALE_RUN_AFTER + 1.minute).ago,
    )

    ShopifyClient.stubs(:configured?).returns(true)
    CatalogSyncer.stubs(:sync!).returns({ products: 1, variants: 1, orders: { "nodes" => [] } })
    LedgerImporter.stubs(:from_shopify_orders!).returns(nil)
    SquareClient.stubs(:configured?).returns(false)
    AlertGenerator.stubs(:sync!).returns({ created: 0, resolved: 0 })
    Reconciler.stubs(:build_rows).returns([])
    Reconciler.stubs(:record_run!).returns(nil)

    run = SyncEngine.run!(mode: "scheduled", actor: "scheduler")

    assert_predicate run, :success?
    assert_predicate orphan.reload, :failed?
    assert_equal 0, SyncRun.unscoped.where(status: "running").count, "only the new run exists, no orphans"
  end

  test "a Square sync (read-only mirror) still runs while Square is frozen" do
    assert PlatformPushGuard.frozen?("square")

    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).returns({ items: [], variations: [], levels: [], links: [], orders: [], locations: [] })
    LedgerImporter.stubs(:from_square_orders!).returns(nil)

    run = SyncEngine.run_source!("square", actor: "user")

    assert_predicate run, :success?
    assert_equal "square", run.source
  end

  test "a frozen Square no longer blocks outbound writes (guard removed)" do
    assert PlatformPushGuard.frozen?("square")
    assert PlatformPushGuard.authorize!("square", actor: "user")
  end

  test "Current.sync_run is set for the duration of a sync and reset after" do
    SquareClient.stubs(:configured?).returns(true)
    SquareSyncer.stubs(:sync!).returns({ items: [], variations: [], levels: [], links: [], orders: [], locations: [] })
    captured = nil
    LedgerImporter.stubs(:from_square_orders!).with { |_orders| captured = Current.sync_run_id; true }.returns(nil)

    run = SyncEngine.run_source!("square", actor: "user")

    assert_equal run.id, captured
    assert_nil Current.sync_run_id
  end
end
