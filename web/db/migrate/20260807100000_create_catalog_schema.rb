# frozen_string_literal: true

# Port of the Prisma schema (legacy/prisma/schema.prisma) to ActiveRecord.
# Table and column names are preserved verbatim so the existing SQLite
# database can be imported with `bin/rails db:import_legacy`.

class CreateCatalogSchema < ActiveRecord::Migration[7.1]
  def change
    create_table "ShopifyProduct", id: :string do |t|
      t.string  "title", null: false
      t.string  "status", default: "ACTIVE"
      t.string  "handle"
      t.datetime "publishedAt"
      t.integer "totalInventory", default: 0
      t.string  "tags"
      t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "ShopifyProduct", ["title"]
    add_index "ShopifyProduct", ["status"]

    create_table "ShopifyVariant", id: :string do |t|
      t.string  "productId", null: false
      t.string  "title", null: false
      t.string  "sku"
      t.string  "barcode"
      t.float   "price"
      t.float   "compareAtPrice"
      t.integer "inventoryQuantity", default: 0
      t.boolean "tracked", default: false
      t.string  "inventoryItemId"
      t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "ShopifyVariant", ["productId"]
    add_index "ShopifyVariant", ["sku"]
    add_index "ShopifyVariant", ["tracked"]

    create_table "SquareItem", id: :string do |t|
      t.string  "name", null: false
      t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end

    create_table "SquareVariation", id: :string do |t|
      t.string  "itemId", null: false
      t.string  "sku"
      t.string  "name", null: false
      t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "SquareVariation", ["itemId"]
    add_index "SquareVariation", ["sku"]

    create_table "SkuLink", id: :string do |t|
      t.string  "sku", null: false
      t.string  "shopifyVariantId"
      t.string  "squareVariationId"
      t.string  "matchSource", default: "sku"
      t.boolean "auto", default: true
      t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "SkuLink", ["sku"]
    add_index "SkuLink", ["shopifyVariantId"]
    add_index "SkuLink", ["shopifyVariantId", "squareVariationId"], unique: true, name: "SkuLink_shopifyVariantId_squareVariationId_key"

    create_table "ReconcileRun", id: :string do |t|
      t.string  "mode", default: "manual"
      t.string  "status", default: "pending"
      t.integer "totalRows", default: 0
      t.integer "actionable", default: 0
      t.integer "applied", default: 0
      t.integer "failed", default: 0
      t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
      t.datetime "finishedAt"
    end
    add_index "ReconcileRun", ["status"]
    add_index "ReconcileRun", ["startedAt"]

    create_table "ReconcileItem", id: :string do |t|
      t.string  "runId", null: false
      t.string  "sku", null: false
      t.string  "product"
      t.string  "variant"
      t.boolean "tracked", default: false
      t.string  "priority", default: "lowest"
      t.integer "shopifyQty"
      t.integer "squareQty"
      t.integer "target"
      t.integer "drift"
      t.integer "shopifyDelta"
      t.integer "squareDelta"
      t.boolean "ok"
      t.string  "actions"
    end
    add_index "ReconcileItem", ["runId"]
    add_index "ReconcileItem", ["sku"]

    create_table "Location", id: :string do |t|
      t.string  "source", null: false
      t.string  "externalId", null: false
      t.string  "name", null: false
      t.string  "kind"
      t.string  "timezone"
      t.boolean "active", default: true
      t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "Location", ["source"]
    add_index "Location", ["source", "externalId"], unique: true

    create_table "InventoryLevel", id: :string do |t|
      t.string  "source", null: false
      t.string  "locationId", null: false
      t.string  "shopifyVariantId"
      t.string  "squareVariationId"
      t.integer "quantity", default: 0
      t.integer "available", default: 0
      t.datetime "updatedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "InventoryLevel", ["locationId"]
    add_index "InventoryLevel", ["shopifyVariantId"]
    add_index "InventoryLevel", ["source", "locationId", "shopifyVariantId"], unique: true
    add_index "InventoryLevel", ["source", "locationId", "squareVariationId"], unique: true

    create_table "InventoryMovement", id: :string do |t|
      t.string  "sku"
      t.string  "shopifyVariantId"
      t.string  "squareVariationId"
      t.string  "source", null: false
      t.string  "direction", null: false
      t.integer "delta", default: 0
      t.integer "quantityBefore", null: false
      t.integer "quantityAfter", null: false
      t.string  "reason"
      t.string  "reference"
      t.string  "actor"
      t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    end
    add_index "InventoryMovement", ["shopifyVariantId"]
    add_index "InventoryMovement", ["createdAt"]
    add_index "InventoryMovement", ["source"]

    create_table "StockAlert", id: :string do |t|
      t.string  "shopifyVariantId"
      t.string  "squareVariationId"
      t.string  "sku"
      t.integer "quantity", default: 0
      t.integer "threshold", default: 5
      t.string  "status", default: "open"
      t.string  "note"
      t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
      t.datetime "resolvedAt"
    end
    add_index "StockAlert", ["status"]
    add_index "StockAlert", ["shopifyVariantId"]
    add_index "StockAlert", ["squareVariationId"]

    create_table "SyncRun", id: :string do |t|
      t.string  "mode", null: false
      t.string  "status", null: false
      t.string  "source"
      t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
      t.datetime "finishedAt"
      t.string  "error"
      t.string  "details"
      t.string  "actor", default: "scheduler"
    end
    add_index "SyncRun", ["startedAt"]
    add_index "SyncRun", ["status"]

    create_table "InventoryPolicy", primary_key: "sku", id: :string do |t|
      t.string  "priority", default: "lowest"
      t.integer "min"
      t.integer "max"
      t.string  "note"
      t.datetime "updatedAt", null: false
    end
    add_index "InventoryPolicy", ["priority"]

    create_table "LedgerEntry", id: :string do |t|
      t.string  "source", null: false
      t.string  "sourceOrderId", null: false
      t.string  "orderName"
      t.datetime "occurredAt", null: false
      t.string  "currency", null: false
      t.integer "grossCents", null: false
      t.string  "status", null: false
      t.integer "lineItems", null: false
      t.string  "summary"
      t.datetime "syncedAt", null: false
    end
    add_index "LedgerEntry", ["source"]
    add_index "LedgerEntry", ["occurredAt"]
  end
end
