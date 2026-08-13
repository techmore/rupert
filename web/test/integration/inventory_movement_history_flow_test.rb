# frozen_string_literal: true

require "test_helper"

class InventoryMovementHistoryFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "Movement Co", subdomain: "movco#{SecureRandom.hex(4)}")
    @admin = User.create!(email: "mov-admin@example.com", password: "password123", role: "admin", name: "Admin", tenant_id: @tenant.id)
    post login_path, params: { email: @admin.email, password: "password123" }
    Current.tenant = @tenant
  end

  teardown do
    Current.tenant = nil
  end

  def create_movement!(sku:, source:, reason:, delta:, before:, after:, actor:, at: 1.hour.ago)
    InventoryMovement.create!(
      sku: sku, source: source, direction: delta.negative? ? "out" : "in",
      delta: delta, quantityBefore: before, quantityAfter: after,
      reason: reason, actor: actor, createdAt: at,
    )
  end

  test "movements page lists changes with source, reason, actor, and before to after" do
    create_movement!(sku: "HERB-1", source: "square", reason: "Synced from Square",
      delta: -1, before: 32, after: 31, actor: "system", at: 30.minutes.ago)
    create_movement!(sku: "HERB-2", source: "reconcile", reason: "Reconciliation applied",
      delta: 4, before: 6, after: 10, actor: "alice@example.com", at: 2.hours.ago)

    get movements_inventory_index_path

    assert_response :success
    assert_includes response.body, "HERB-1"
    assert_includes response.body, "Synced from Square"
    assert_includes response.body, "Square sync"
    assert_match(/32 → <span[^>]*>31<\/span>/, response.body)
    assert_includes response.body, "HERB-2"
    assert_includes response.body, "Reconciliation applied"
    assert_includes response.body, "alice@example.com"
    assert_match(/6 → <span[^>]*>10<\/span>/, response.body)
  end

  test "SKU filter narrows the ledger" do
    create_movement!(sku: "HERB-A", source: "square", reason: "Synced from Square", delta: 1, before: 0, after: 1, actor: "system")
    create_movement!(sku: "BALM-B", source: "shopify", reason: "Synced from Shopify", delta: 1, before: 0, after: 1, actor: "system")

    get movements_inventory_index_path, params: { q: "HERB-A" }

    assert_response :success
    assert_includes response.body, "HERB-A"
    assert_not_includes response.body, "BALM-B"
  end

  test "source filter narrows the ledger" do
    create_movement!(sku: "HERB-A", source: "square", reason: "Synced from Square", delta: 1, before: 0, after: 1, actor: "system")
    create_movement!(sku: "HERB-B", source: "shopify", reason: "Synced from Shopify", delta: 1, before: 0, after: 1, actor: "system")

    get movements_inventory_index_path, params: { source: "shopify" }

    assert_response :success
    assert_includes response.body, "HERB-B"
    assert_not_includes response.body, "HERB-A"
  end

  test "a negative change is shown as a loss in the ledger" do
    create_movement!(sku: "HERB-N", source: "square", reason: "Synced from Square",
      delta: -3, before: 5, after: 2, actor: "system")

    get movements_inventory_index_path

    assert_response :success
    assert_includes response.body, "-3"
    assert_match(/5 → <span[^>]*>2<\/span>/, response.body)
  end

  test "movements captured by a sync show its run id in the ledger" do
    run = SyncRun.create!(mode: "scheduled", status: "success", source: "all",
      startedAt: 1.hour.ago, tenant_id: @tenant.id)
    create_movement!(sku: "HERB-S", source: "square", reason: "Synced from Square",
      delta: 1, before: 0, after: 1, actor: "system").update!(syncRunId: run.id)

    get movements_inventory_index_path

    assert_response :success
    assert_includes response.body, run.id.to_s.first(8)
  end
end
