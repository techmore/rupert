class CreateWarehouseTiers < ActiveRecord::Migration[7.1]
  def change
    create_table "WarehouseTier", id: :string do |t|
      t.string  "shareId"
      t.integer "minQty", null: false
      t.decimal "discountPercent", null: false, precision: 10, scale: 4
      t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "WarehouseTier", ["shareId"]
    add_index "WarehouseTier", ["shareId", "minQty"], unique: true
  end
end
