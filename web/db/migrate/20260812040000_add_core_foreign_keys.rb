# frozen_string_literal: true

# Add referential integrity to the core tables. All relationships were
# verified orphan-free before running, so each FK applies cleanly. Children
# cascade with their parent; mirror links/levels null out when a catalog row
# disappears so re-syncs can recreate them.
class AddCoreForeignKeys < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key '"ReconcileItem"', '"ReconcileRun"', column: :runId, on_delete: :cascade

    %i[order_lines payments fulfillments refunds].each do |table|
      add_foreign_key table, :orders, on_delete: :cascade
    end

    add_foreign_key '"SkuLink"', '"ShopifyVariant"', column: :shopifyVariantId, on_delete: :nullify
    add_foreign_key '"SkuLink"', '"SquareVariation"', column: :squareVariationId, on_delete: :nullify

    add_foreign_key '"InventoryLevel"', '"ShopifyVariant"', column: :shopifyVariantId, on_delete: :nullify
    add_foreign_key '"InventoryLevel"', '"SquareVariation"', column: :squareVariationId, on_delete: :nullify

    add_foreign_key :size_family_members, :size_families, column: :family_id, on_delete: :cascade
    add_foreign_key :size_changes, :size_families, column: :family_id, on_delete: :cascade
  end
end
