class CreateWarehouseShares < ActiveRecord::Migration[7.1]
  def change
    create_table "WarehouseShare", id: :string do |t|
      t.string  "name", null: false
      t.string  "token", null: false
      t.decimal "priceMultiplier", default: "1.0", null: false, precision: 10, scale: 4
      t.string  "status", default: "active", null: false
      t.boolean "useCustomTiers", default: false, null: false
      t.string  "tenantId"
      t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "WarehouseShare", ["token"], unique: true
    add_index "WarehouseShare", ["tenantId"]
  end
end
