# frozen_string_literal: true

# Lookup indexes for hot read paths that were full-scanning:
# - orders.order_number: public warehouse order lookup + global search
# - ShopifyVariant.inventoryItemId: natural key for Shopify inventory APIs
# - SkuLink.squareVariationId: standalone lookups (multiloc guards, shared-pool
#   checks) previously served only by the composite (shopifyVariantId, …) key
# - InventoryMovement.sku / .squareVariationId: movement ledger filters and
#   per-variation history joins on the fastest-growing table
class AddLookupIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :orders, [:tenant_id, :order_number],
      name: "index_orders_on_tenant_id_and_order_number"

    add_index :"ShopifyVariant", [:tenant_id, :inventoryItemId],
      name: "idx_shopify_variants_tenant_inventory_item_id"

    add_index :"SkuLink", [:tenant_id, :squareVariationId],
      name: "idx_sku_links_tenant_square_variation"

    add_index :"InventoryMovement", [:tenant_id, :sku],
      name: "idx_inventory_movements_tenant_sku"
    add_index :"InventoryMovement", [:tenant_id, :squareVariationId],
      name: "idx_inventory_movements_tenant_square_variation"
  end
end
