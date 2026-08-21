# frozen_string_literal: true

require "test_helper"

class DataRetentionTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant_id = Current.tenant_id
    @variant = ShopifyVariant.create!(productId: "p-ret", title: "Tea", sku: "RET-1")
  end

  teardown { Current.tenant = nil }

  def backfill_movement!(age:)
    InventoryMovement.create!(sku: "RET-1", source: "sync", direction: "set", delta: 0,
      quantityBefore: 0, quantityAfter: 0, createdAt: age.ago)
  end

  test "prunes rows older than the window and keeps fresh ones" do
    old = backfill_movement!(age: 200.days)
    fresh = backfill_movement!(age: 2.days)

    deleted = DataRetention.prune(InventoryMovement, column: "createdAt", older_than: 180.days.ago)

    assert_equal 1, deleted
    assert_not InventoryMovement.exists?(old.id)
    assert InventoryMovement.exists?(fresh.id)
  end

  test "prune_all! covers the policy tables" do
    backfill_movement!(age: 400.days)
    LedgerEntry.create!(source: "shopify", sourceOrderId: "ord-1", status: "paid",
      currency: "USD", grossCents: 100, lineItems: 1, occurredAt: 400.days.ago,
      syncedAt: 400.days.ago)

    totals = DataRetention.prune_all!

    assert_operator totals["InventoryMovement"], :>=, 1
    assert_operator totals["LedgerEntry"], :>=, 1
  end

  test "respects tenant isolation" do
    other = Tenant.create!(name: "Other Shop", subdomain: "other-retention")
    Current.tenant = other
    backfill_movement!(age: 400.days)

    Current.tenant = tenants(:default_tenant)
    backfill_movement!(age: 400.days)
    deleted = DataRetention.prune_all!

    assert_equal 1, deleted["InventoryMovement"]
    assert_equal 1, InventoryMovement.unscoped.where(tenant_id: other.id).count
  ensure
    Current.tenant = tenants(:default_tenant) if Current.tenant.nil?
  end
end
