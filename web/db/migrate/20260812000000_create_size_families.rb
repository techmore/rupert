# frozen_string_literal: true

class CreateSizeFamilies < ActiveRecord::Migration[8.1]
  def change
    create_table :size_families do |t|
      t.string :tenant_id
      t.string :name, null: false
      t.string :root_sku
      t.decimal :base_grams, precision: 12, scale: 3
      t.datetime :sales_watermark
      t.string :mode, default: "approval", null: false
      t.timestamps
    end
    add_index :size_families, :tenant_id

    create_table :size_family_members do |t|
      t.string :tenant_id
      t.bigint :family_id, null: false
      t.string :sku, null: false
      t.decimal :grams, precision: 12, scale: 3, null: false
      t.string :square_variation_id
      t.string :shopify_variant_id
      t.timestamps
    end
    add_index :size_family_members, :tenant_id
    add_index :size_family_members, :family_id
    add_index :size_family_members, [:family_id, :sku], unique: true

    create_table :size_changes do |t|
      t.string :tenant_id
      t.bigint :family_id, null: false
      t.string :sku, null: false
      t.decimal :grams, precision: 12, scale: 3
      t.decimal :root_grams, precision: 12, scale: 3
      t.integer :target_quantity
      t.string :square_variation_id
      t.string :status, default: "pending", null: false
      t.string :mode
      t.string :error
      t.timestamps
    end
    add_index :size_changes, :tenant_id
    add_index :size_changes, :family_id
    add_index :size_changes, [:family_id, :sku], unique: true
  end
end
