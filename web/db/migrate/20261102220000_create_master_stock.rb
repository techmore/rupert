# frozen_string_literal: true

# Rupert-owned stock: sites, items, exact platform links, balances and an
# append-only movement ledger. No platform stock is written by these tables.
class CreateMasterStock < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_sites do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :shopify_location_id
      t.string :ctrax_location_id
      t.string :square_location_id
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :stock_sites, %i[tenant_id name], unique: true
    add_index :stock_sites, %i[tenant_id shopify_location_id], unique: true, where: 'shopify_location_id IS NOT NULL'
    add_index :stock_sites, %i[tenant_id ctrax_location_id], unique: true, where: 'ctrax_location_id IS NOT NULL'
    add_index :stock_sites, %i[tenant_id square_location_id], unique: true, where: 'square_location_id IS NOT NULL'

    create_table :stock_items do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.string :sku
      t.string :barcode
      t.boolean :active, null: false, default: true
      t.string :created_by, null: false
      t.timestamps
    end
    add_index :stock_items, %i[tenant_id name]
    add_index :stock_items, %i[tenant_id sku]
    add_index :stock_items, %i[tenant_id barcode]

    create_table :stock_item_links do |t|
      t.string :tenant_id, null: false
      t.references :stock_item, null: false, foreign_key: true
      t.references :stock_site, null: false, foreign_key: true
      t.string :platform, null: false
      t.string :native_item_id, null: false
      t.string :match_source, null: false, default: 'manual'
      t.string :linked_by, null: false
      t.timestamps
    end
    add_index :stock_item_links, %i[tenant_id stock_site_id platform native_item_id], unique: true, name: 'idx_stock_item_links_native'
    add_index :stock_item_links, %i[tenant_id stock_item_id stock_site_id platform], unique: true, name: 'idx_stock_item_links_one_per_platform'
    add_check_constraint :stock_item_links, "platform IN ('shopify', 'ctrax', 'square')", name: 'stock_item_links_platform'

    create_table :stock_balances do |t|
      t.string :tenant_id, null: false
      t.references :stock_item, null: false, foreign_key: true
      t.references :stock_site, null: false, foreign_key: true
      t.integer :on_hand, null: false
      t.datetime :counted_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :stock_balances, %i[tenant_id stock_item_id stock_site_id], unique: true, name: 'idx_stock_balances_pool'
    add_check_constraint :stock_balances, 'on_hand >= 0', name: 'stock_balances_non_negative'

    create_table :stock_ledger_entries do |t|
      t.string :tenant_id, null: false
      t.references :stock_item, null: false, foreign_key: true
      t.references :stock_site, null: false, foreign_key: true
      t.string :kind, null: false
      t.integer :delta, null: false
      t.integer :quantity_before
      t.integer :quantity_after, null: false
      t.string :reason
      t.text :note
      t.string :reference
      t.string :origin, null: false, default: 'rupert'
      t.string :transfer_group
      t.string :actor, null: false
      t.string :request_token, null: false
      t.string :payload_digest, null: false
      t.datetime :created_at, null: false
    end
    add_index :stock_ledger_entries, %i[tenant_id request_token stock_site_id], unique: true, name: 'idx_stock_ledger_token'
    add_index :stock_ledger_entries, %i[tenant_id stock_item_id stock_site_id], name: 'idx_stock_ledger_pool'
    add_index :stock_ledger_entries, %i[tenant_id created_at]
    add_check_constraint :stock_ledger_entries, "kind IN ('count', 'receive', 'adjust', 'transfer_out', 'transfer_in', 'sale', 'return')", name: 'stock_ledger_kind'
    add_check_constraint :stock_ledger_entries, "origin IN ('rupert', 'shopify', 'ctrax', 'square')", name: 'stock_ledger_origin'
    add_check_constraint :stock_ledger_entries, 'quantity_after >= 0', name: 'stock_ledger_non_negative'
  end
end
