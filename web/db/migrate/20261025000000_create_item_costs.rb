# frozen_string_literal: true

# Cost of goods for one Shopify variant, entered by a person in Rupert. Stored in Rupert only; nothing is written
# to Shopify, Square or C-Trax. It wins over the C-Trax cost on the item page; removing it falls back to C-Trax.
class CreateItemCosts < ActiveRecord::Migration[8.1]
  def change
    create_table :item_costs do |t|
      t.string :tenant_id, null: false
      t.string :shopify_variant_id, null: false
      t.integer :cost_cents, null: false
      t.bigint :updated_by_id
      t.timestamps
    end
    add_index :item_costs, %i[tenant_id shopify_variant_id], unique: true
  end
end
