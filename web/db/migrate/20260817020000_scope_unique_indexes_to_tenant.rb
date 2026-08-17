# frozen_string_literal: true

# The Location and InventoryLevel unique indexes were keyed without
# tenant_id, so a second tenant syncing the same Shopify/Square external IDs
# could collide on upsert or silently adopt another tenant's rows. Scope the
# unique constraints per tenant (single-tenant data today, so safe to apply).
class ScopeUniqueIndexesToTenant < ActiveRecord::Migration[8.1]
  def up
    remove_index :"Location", name: "index_Location_on_source_and_externalId"
    add_index :"Location", [:tenant_id, :source, :externalId],
      name: "index_Location_on_tenant_source_externalId", unique: true

    remove_index :"InventoryLevel", name: "idx_on_source_locationId_shopifyVariantId_9ef5a647f1"
    remove_index :"InventoryLevel", name: "idx_on_source_locationId_squareVariationId_4ae41ea9a8"
    add_index :"InventoryLevel", [:tenant_id, :source, :locationId, :shopifyVariantId],
      name: "idx_inventory_levels_tenant_source_loc_shopify", unique: true
    add_index :"InventoryLevel", [:tenant_id, :source, :locationId, :squareVariationId],
      name: "idx_inventory_levels_tenant_source_loc_square", unique: true
  end

  def down
    remove_index :"Location", name: "index_Location_on_tenant_source_externalId"
    add_index :"Location", [:source, :externalId], name: "index_Location_on_source_and_externalId", unique: true

    remove_index :"InventoryLevel", name: "idx_inventory_levels_tenant_source_loc_shopify"
    remove_index :"InventoryLevel", name: "idx_inventory_levels_tenant_source_loc_square"
    add_index :"InventoryLevel", [:source, :locationId, :shopifyVariantId],
      name: "idx_on_source_locationId_shopifyVariantId_9ef5a647f1", unique: true
    add_index :"InventoryLevel", [:source, :locationId, :squareVariationId],
      name: "idx_on_source_locationId_squareVariationId_4ae41ea9a8", unique: true
  end
end