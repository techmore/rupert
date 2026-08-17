# frozen_string_literal: true

# Indexes for the hottest read paths surfaced in the performance audit:
# the 15-minute sync's square-total aggregations, per-variant sold sums,
# report/ledger range scans, and the last-sync + reconcile lookups.
class AddPerformanceIndexes < ActiveRecord::Migration[8.1]
  def change
    # Legacy camelCase mirror tables (quoted to match their physical names).
    add_index :"InventoryLevel",
      [:tenant_id, :source, :squareVariationId],
      name: "idx_inventory_levels_tenant_source_square_variation"
    add_index :"InventoryLevel",
      [:tenant_id, :source, :shopifyVariantId],
      name: "idx_inventory_levels_tenant_source_shopify_variant"
    add_index :"LedgerEntry", [:tenant_id, :occurredAt], name: "idx_ledger_entries_tenant_occurred_at"
    add_index :"InventoryMovement",
      [:tenant_id, :source, :createdAt],
      name: "idx_inventory_movements_tenant_source_created_at"
    add_index :"SyncRun", [:status, :finishedAt], name: "idx_sync_runs_status_finished_at"
    add_index :"ShopifyVariant", [:sku, :productId], name: "idx_shopify_variants_sku_product"

    # Modern snake_case tables.
    add_index :orders, :location_id
    add_index :size_changes, [:tenant_id, :status]
  end
end