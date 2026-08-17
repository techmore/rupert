# frozen_string_literal: true

require "test_helper"

class ReconcilerTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def sample_row
    Reconciler::Row.new(
      sku: "TEST-1",
      product: "Test Product",
      variant: "One",
      variant_id: "v1",
      inventory_item_id: "ii1",
      tracked: true,
      priority: "lowest",
      shopify_qty: 5,
      square_qty: 5,
      square_home_qty: 5,
      target: 5,
      drift: 0,
      shopify_delta: 0,
      square_delta: 0,
      square_home_target: 5,
      square_variation_id: "sv1",
      derived: false,
      image_url: nil,
    )
  end

  test "record_run! bulk-inserts items and links them to the run" do
    run = Reconciler.record_run!([sample_row], mode: "manual")

    assert run.persisted?
    items = ReconcileItem.where(runId: run.id)
    assert_equal 1, items.count
    assert_equal "TEST-1", items.first.sku
    assert_equal 5, items.first.shopifyQty
    assert_equal 0, items.first.shopifyDelta
  end

  test "prune_old_runs! removes runs older than the retention window" do
    old_run = ReconcileRun.create!(mode: "scheduled", status: "pending", startedAt: 40.days.ago, totalRows: 1)
    ReconcileItem.create!(runId: old_run.id, sku: "OLD-1", tenant_id: @tenant.id)
    fresh_run = ReconcileRun.create!(mode: "scheduled", status: "pending", startedAt: 1.day.ago, totalRows: 1)

    Reconciler.prune_old_runs!(keep: 30.days)

    assert_nil ReconcileRun.find_by(id: old_run.id)
    assert_equal 0, ReconcileItem.where(runId: old_run.id).count
    assert ReconcileRun.exists?(fresh_run.id)
  end
end