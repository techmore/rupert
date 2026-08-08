# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_08_07_120000) do
  create_table "InventoryLevel", id: :string, force: :cascade do |t|
    t.string "source", null: false
    t.string "locationId", null: false
    t.string "shopifyVariantId"
    t.string "squareVariationId"
    t.integer "quantity", default: 0
    t.integer "available", default: 0
    t.datetime "updatedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["locationId"], name: "index_InventoryLevel_on_locationId"
    t.index ["shopifyVariantId"], name: "index_InventoryLevel_on_shopifyVariantId"
    t.index ["source", "locationId", "shopifyVariantId"], name: "idx_on_source_locationId_shopifyVariantId_9ef5a647f1", unique: true
    t.index ["source", "locationId", "squareVariationId"], name: "idx_on_source_locationId_squareVariationId_4ae41ea9a8", unique: true
  end

  create_table "InventoryMovement", id: :string, force: :cascade do |t|
    t.string "sku"
    t.string "shopifyVariantId"
    t.string "squareVariationId"
    t.string "source", null: false
    t.string "direction", null: false
    t.integer "delta", default: 0
    t.integer "quantityBefore", null: false
    t.integer "quantityAfter", null: false
    t.string "reason"
    t.string "reference"
    t.string "actor"
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["createdAt"], name: "index_InventoryMovement_on_createdAt"
    t.index ["shopifyVariantId"], name: "index_InventoryMovement_on_shopifyVariantId"
    t.index ["source"], name: "index_InventoryMovement_on_source"
  end

  create_table "InventoryPolicy", primary_key: "sku", id: :string, force: :cascade do |t|
    t.string "priority", default: "lowest"
    t.integer "min"
    t.integer "max"
    t.string "note"
    t.datetime "updatedAt", null: false
    t.index ["priority"], name: "index_InventoryPolicy_on_priority"
  end

  create_table "LedgerEntry", id: :string, force: :cascade do |t|
    t.string "source", null: false
    t.string "sourceOrderId", null: false
    t.string "orderName"
    t.datetime "occurredAt", null: false
    t.string "currency", null: false
    t.integer "grossCents", null: false
    t.string "status", null: false
    t.integer "lineItems", null: false
    t.string "summary"
    t.datetime "syncedAt", null: false
    t.index ["occurredAt"], name: "index_LedgerEntry_on_occurredAt"
    t.index ["source"], name: "index_LedgerEntry_on_source"
  end

  create_table "Location", id: :string, force: :cascade do |t|
    t.string "source", null: false
    t.string "externalId", null: false
    t.string "name", null: false
    t.string "kind"
    t.string "timezone"
    t.boolean "active", default: true
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["source", "externalId"], name: "index_Location_on_source_and_externalId", unique: true
    t.index ["source"], name: "index_Location_on_source"
  end

  create_table "ReconcileItem", id: :string, force: :cascade do |t|
    t.string "runId", null: false
    t.string "sku", null: false
    t.string "product"
    t.string "variant"
    t.boolean "tracked", default: false
    t.string "priority", default: "lowest"
    t.integer "shopifyQty"
    t.integer "squareQty"
    t.integer "target"
    t.integer "drift"
    t.integer "shopifyDelta"
    t.integer "squareDelta"
    t.boolean "ok"
    t.string "actions"
    t.index ["runId"], name: "index_ReconcileItem_on_runId"
    t.index ["sku"], name: "index_ReconcileItem_on_sku"
  end

  create_table "ReconcileRun", id: :string, force: :cascade do |t|
    t.string "mode", default: "manual"
    t.string "status", default: "pending"
    t.integer "totalRows", default: 0
    t.integer "actionable", default: 0
    t.integer "applied", default: 0
    t.integer "failed", default: 0
    t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "finishedAt"
    t.index ["startedAt"], name: "index_ReconcileRun_on_startedAt"
    t.index ["status"], name: "index_ReconcileRun_on_status"
  end

  create_table "ShopifyProduct", id: :string, force: :cascade do |t|
    t.string "title", null: false
    t.string "status", default: "ACTIVE"
    t.string "handle"
    t.datetime "publishedAt"
    t.integer "totalInventory", default: 0
    t.string "tags"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["status"], name: "index_ShopifyProduct_on_status"
    t.index ["title"], name: "index_ShopifyProduct_on_title"
  end

  create_table "ShopifyVariant", id: :string, force: :cascade do |t|
    t.string "productId", null: false
    t.string "title", null: false
    t.string "sku"
    t.string "barcode"
    t.float "price"
    t.float "compareAtPrice"
    t.integer "inventoryQuantity", default: 0
    t.boolean "tracked", default: false
    t.string "inventoryItemId"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["productId"], name: "index_ShopifyVariant_on_productId"
    t.index ["sku"], name: "index_ShopifyVariant_on_sku"
    t.index ["tracked"], name: "index_ShopifyVariant_on_tracked"
  end

  create_table "SkuLink", id: :string, force: :cascade do |t|
    t.string "sku", null: false
    t.string "shopifyVariantId"
    t.string "squareVariationId"
    t.string "matchSource", default: "sku"
    t.boolean "auto", default: true
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["shopifyVariantId", "squareVariationId"], name: "SkuLink_shopifyVariantId_squareVariationId_key", unique: true
    t.index ["shopifyVariantId"], name: "index_SkuLink_on_shopifyVariantId"
    t.index ["sku"], name: "index_SkuLink_on_sku"
  end

  create_table "SquareItem", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
  end

  create_table "SquareVariation", id: :string, force: :cascade do |t|
    t.string "itemId", null: false
    t.string "sku"
    t.string "name", null: false
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["itemId"], name: "index_SquareVariation_on_itemId"
    t.index ["sku"], name: "index_SquareVariation_on_sku"
  end

  create_table "StockAlert", id: :string, force: :cascade do |t|
    t.string "shopifyVariantId"
    t.string "squareVariationId"
    t.string "sku"
    t.integer "quantity", default: 0
    t.integer "threshold", default: 5
    t.string "status", default: "open"
    t.string "note"
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "resolvedAt"
    t.index ["shopifyVariantId"], name: "index_StockAlert_on_shopifyVariantId"
    t.index ["squareVariationId"], name: "index_StockAlert_on_squareVariationId"
    t.index ["status"], name: "index_StockAlert_on_status"
  end

  create_table "SyncRun", id: :string, force: :cascade do |t|
    t.string "mode", null: false
    t.string "status", null: false
    t.string "source"
    t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "finishedAt"
    t.string "error"
    t.string "details"
    t.string "actor", default: "scheduler"
    t.index ["startedAt"], name: "index_SyncRun_on_startedAt"
    t.index ["status"], name: "index_SyncRun_on_status"
  end

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.string "value"
    t.datetime "updated_at"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "shops", force: :cascade do |t|
    t.string "shopify_domain", null: false
    t.string "shopify_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "access_scopes"
    t.datetime "expires_at"
    t.string "refresh_token"
    t.datetime "refresh_token_expires_at"
    t.index ["shopify_domain"], name: "index_shops_on_shopify_domain", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "shopify_user_id", null: false
    t.string "shopify_domain", null: false
    t.string "shopify_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "access_scopes", default: "", null: false
    t.datetime "expires_at"
    t.index ["shopify_user_id"], name: "index_users_on_shopify_user_id", unique: true
  end

  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
