# frozen_string_literal: true

class CreateWarehouseCarts < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouse_carts do |t|
      t.string :tenant_id, null: false
      t.string :share_id, null: false
      t.string :token, null: false
      t.string :status, default: "open", null: false
      t.timestamps

      t.index :token, unique: true
      t.index [:tenant_id, :share_id]
    end

    create_table :warehouse_cart_items do |t|
      t.bigint :cart_id, null: false
      t.string :tenant_id, null: false
      t.string :share_id, null: false
      t.string :variant_id, null: false
      t.string :sku
      t.string :title
      t.integer :quantity, default: 0, null: false
      t.integer :unit_cents, default: 0, null: false
      t.integer :line_cents, default: 0, null: false
      t.timestamps

      t.index [:cart_id, :variant_id], unique: true
      t.index [:tenant_id, :share_id]
    end
  end
end
