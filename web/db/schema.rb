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

ActiveRecord::Schema[8.1].define(version: 2026_08_09_040000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "BackupLog", id: :string, force: :cascade do |t|
    t.string "driveFileId"
    t.string "driveUrl"
    t.text "error"
    t.string "fileName"
    t.integer "fileSize"
    t.datetime "finishedAt"
    t.datetime "startedAt", null: false
    t.string "status", default: "running", null: false
    t.string "tenant_id"
    t.index ["tenant_id", "startedAt"], name: "index_BackupLog_on_tenant_id_and_startedAt"
  end

  create_table "InventoryCount", id: :string, force: :cascade do |t|
    t.datetime "appliedAt"
    t.datetime "approvedAt"
    t.datetime "countedAt", null: false
    t.string "createdBy"
    t.string "locationId"
    t.string "note"
    t.string "status", default: "draft", null: false
    t.string "tenant_id"
    t.index ["tenant_id", "countedAt"], name: "index_InventoryCount_on_tenant_id_and_countedAt"
  end

  create_table "InventoryCountItem", id: :string, force: :cascade do |t|
    t.boolean "applied", default: false, null: false
    t.string "countId", null: false
    t.integer "previousQuantity"
    t.integer "quantity", default: 0, null: false
    t.string "shopifyVariantId"
    t.string "sku", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.index ["countId"], name: "index_InventoryCountItem_on_countId"
    t.index ["tenant_id"], name: "index_InventoryCountItem_on_tenant_id"
  end

  create_table "InventoryLevel", id: :string, force: :cascade do |t|
    t.integer "available", default: 0
    t.string "locationId", null: false
    t.integer "quantity", default: 0
    t.string "shopifyVariantId"
    t.string "source", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.datetime "updatedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["locationId"], name: "index_InventoryLevel_on_locationId"
    t.index ["shopifyVariantId"], name: "index_InventoryLevel_on_shopifyVariantId"
    t.index ["source", "locationId", "shopifyVariantId"], name: "idx_on_source_locationId_shopifyVariantId_9ef5a647f1", unique: true
    t.index ["source", "locationId", "squareVariationId"], name: "idx_on_source_locationId_squareVariationId_4ae41ea9a8", unique: true
    t.index ["tenant_id"], name: "index_InventoryLevel_on_tenant_id"
  end

  create_table "InventoryMovement", id: :string, force: :cascade do |t|
    t.string "actor"
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.integer "delta", default: 0
    t.string "direction", null: false
    t.integer "quantityAfter", null: false
    t.integer "quantityBefore", null: false
    t.string "reason"
    t.string "reference"
    t.string "shopifyVariantId"
    t.string "sku"
    t.string "source", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.index ["createdAt"], name: "index_InventoryMovement_on_createdAt"
    t.index ["shopifyVariantId"], name: "index_InventoryMovement_on_shopifyVariantId"
    t.index ["source"], name: "index_InventoryMovement_on_source"
    t.index ["tenant_id"], name: "index_InventoryMovement_on_tenant_id"
  end

  create_table "InventoryPolicy", primary_key: "sku", id: :string, force: :cascade do |t|
    t.integer "max"
    t.integer "min"
    t.string "note"
    t.string "priority", default: "lowest"
    t.string "tenant_id"
    t.datetime "updatedAt", null: false
    t.index ["priority"], name: "index_InventoryPolicy_on_priority"
    t.index ["tenant_id"], name: "index_InventoryPolicy_on_tenant_id"
  end

  create_table "LedgerEntry", id: :string, force: :cascade do |t|
    t.string "currency", null: false
    t.integer "grossCents", null: false
    t.integer "lineItems", null: false
    t.datetime "occurredAt", null: false
    t.string "orderName"
    t.string "source", null: false
    t.string "sourceOrderId", null: false
    t.string "status", null: false
    t.string "summary"
    t.datetime "syncedAt", null: false
    t.string "tenant_id"
    t.index ["occurredAt"], name: "index_LedgerEntry_on_occurredAt"
    t.index ["source"], name: "index_LedgerEntry_on_source"
    t.index ["tenant_id"], name: "index_LedgerEntry_on_tenant_id"
  end

  create_table "Location", id: :string, force: :cascade do |t|
    t.boolean "active", default: true
    t.string "externalId", null: false
    t.string "kind"
    t.string "name", null: false
    t.string "source", null: false
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.string "timezone"
    t.index ["source", "externalId"], name: "index_Location_on_source_and_externalId", unique: true
    t.index ["source"], name: "index_Location_on_source"
    t.index ["tenant_id"], name: "index_Location_on_tenant_id"
  end

  create_table "ReconcileItem", id: :string, force: :cascade do |t|
    t.string "actions"
    t.integer "drift"
    t.boolean "ok"
    t.string "priority", default: "lowest"
    t.string "product"
    t.string "runId", null: false
    t.integer "shopifyDelta"
    t.integer "shopifyQty"
    t.string "sku", null: false
    t.integer "squareDelta"
    t.integer "squareQty"
    t.integer "target"
    t.string "tenant_id"
    t.boolean "tracked", default: false
    t.string "variant"
    t.index ["runId"], name: "index_ReconcileItem_on_runId"
    t.index ["sku"], name: "index_ReconcileItem_on_sku"
    t.index ["tenant_id"], name: "index_ReconcileItem_on_tenant_id"
  end

  create_table "ReconcileRun", id: :string, force: :cascade do |t|
    t.integer "actionable", default: 0
    t.integer "applied", default: 0
    t.integer "failed", default: 0
    t.datetime "finishedAt"
    t.string "mode", default: "manual"
    t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "status", default: "pending"
    t.string "tenant_id"
    t.integer "totalRows", default: 0
    t.index ["startedAt"], name: "index_ReconcileRun_on_startedAt"
    t.index ["status"], name: "index_ReconcileRun_on_status"
    t.index ["tenant_id"], name: "index_ReconcileRun_on_tenant_id"
  end

  create_table "ShopifyProduct", id: :string, force: :cascade do |t|
    t.string "featuredImageUrl"
    t.string "handle"
    t.datetime "publishedAt"
    t.string "status", default: "ACTIVE"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tags"
    t.string "tenant_id"
    t.string "title", null: false
    t.integer "totalInventory", default: 0
    t.index ["status"], name: "index_ShopifyProduct_on_status"
    t.index ["tenant_id"], name: "index_ShopifyProduct_on_tenant_id"
    t.index ["title"], name: "index_ShopifyProduct_on_title"
  end

  create_table "ShopifyVariant", id: :string, force: :cascade do |t|
    t.string "barcode"
    t.float "compareAtPrice"
    t.string "inventoryItemId"
    t.integer "inventoryQuantity", default: 0
    t.float "price"
    t.string "productId", null: false
    t.string "sku"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.string "title", null: false
    t.boolean "tracked", default: false
    t.index ["productId"], name: "index_ShopifyVariant_on_productId"
    t.index ["sku"], name: "index_ShopifyVariant_on_sku"
    t.index ["tenant_id"], name: "index_ShopifyVariant_on_tenant_id"
    t.index ["tracked"], name: "index_ShopifyVariant_on_tracked"
  end

  create_table "SkuLink", id: :string, force: :cascade do |t|
    t.boolean "auto", default: true
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "matchSource", default: "sku"
    t.string "shopifyVariantId"
    t.string "sku", null: false
    t.string "squareVariationId"
    t.string "tenant_id"
    t.index ["shopifyVariantId", "squareVariationId"], name: "SkuLink_shopifyVariantId_squareVariationId_key", unique: true
    t.index ["shopifyVariantId"], name: "index_SkuLink_on_shopifyVariantId", unique: true
    t.index ["sku"], name: "index_SkuLink_on_sku"
    t.index ["tenant_id"], name: "index_SkuLink_on_tenant_id"
  end

  create_table "SquareItem", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.index ["tenant_id"], name: "index_SquareItem_on_tenant_id"
  end

  create_table "SquareVariation", id: :string, force: :cascade do |t|
    t.string "itemId", null: false
    t.string "name", null: false
    t.string "sku"
    t.datetime "syncedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "tenant_id"
    t.index ["itemId"], name: "index_SquareVariation_on_itemId"
    t.index ["sku"], name: "index_SquareVariation_on_sku"
    t.index ["tenant_id"], name: "index_SquareVariation_on_tenant_id"
  end

  create_table "StockAlert", id: :string, force: :cascade do |t|
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "note"
    t.integer "quantity", default: 0
    t.datetime "resolvedAt"
    t.string "shopifyVariantId"
    t.string "sku"
    t.string "squareVariationId"
    t.string "status", default: "open"
    t.string "tenant_id"
    t.integer "threshold", default: 5
    t.index ["shopifyVariantId"], name: "index_StockAlert_on_shopifyVariantId"
    t.index ["squareVariationId"], name: "index_StockAlert_on_squareVariationId"
    t.index ["status"], name: "index_StockAlert_on_status"
    t.index ["tenant_id"], name: "index_StockAlert_on_tenant_id"
  end

  create_table "SyncRun", id: :string, force: :cascade do |t|
    t.string "actor", default: "scheduler"
    t.string "details"
    t.string "error"
    t.datetime "finishedAt"
    t.string "mode", null: false
    t.string "source"
    t.datetime "startedAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "status", null: false
    t.string "tenant_id"
    t.index ["startedAt"], name: "index_SyncRun_on_startedAt"
    t.index ["status"], name: "index_SyncRun_on_status"
    t.index ["tenant_id"], name: "index_SyncRun_on_tenant_id"
  end

  create_table "WarehouseShare", id: :string, force: :cascade do |t|
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "name", null: false
    t.decimal "priceMultiplier", precision: 10, scale: 4, default: "1.0", null: false
    t.string "status", default: "active", null: false
    t.string "tenantId"
    t.string "token", null: false
    t.boolean "useCustomTiers", default: false, null: false
    t.index ["tenantId"], name: "index_WarehouseShare_on_tenantId"
    t.index ["token"], name: "index_WarehouseShare_on_token", unique: true
  end

  create_table "WarehouseTier", id: :string, force: :cascade do |t|
    t.datetime "createdAt", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.decimal "discountPercent", precision: 10, scale: 4, null: false
    t.integer "minQty", null: false
    t.string "shareId"
    t.index ["shareId", "minQty"], name: "index_WarehouseTier_on_shareId_and_minQty", unique: true
    t.index ["shareId"], name: "index_WarehouseTier_on_shareId"
  end

  create_table "customers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "external_id", null: false
    t.string "first_name"
    t.string "last_name"
    t.text "notes"
    t.string "phone"
    t.string "source", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "email"], name: "index_customers_on_tenant_id_and_email"
    t.index ["tenant_id", "external_id", "source"], name: "index_customers_on_tenant_id_and_external_id_and_source", unique: true
    t.index ["tenant_id", "phone"], name: "index_customers_on_tenant_id_and_phone"
  end

  create_table "fulfillments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "fulfilled_at"
    t.bigint "order_id", null: false
    t.string "source", default: "manual", null: false
    t.string "source_fulfillment_id"
    t.string "status", default: "pending", null: false
    t.string "tenant_id", null: false
    t.string "tracking_company"
    t.string "tracking_number"
    t.string "tracking_url"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_fulfillments_on_order_id"
    t.index ["source", "source_fulfillment_id"], name: "index_fulfillments_on_source_and_source_fulfillment_id", unique: true
    t.index ["tenant_id", "order_id"], name: "index_fulfillments_on_tenant_id_and_order_id"
  end

  create_table "goals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "current_value", precision: 12, scale: 2, default: "0.0"
    t.text "description"
    t.date "due_on"
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.decimal "target_value", precision: 12, scale: 2
    t.string "tenant_id", null: false
    t.string "unit"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "status"], name: "index_goals_on_tenant_id_and_status"
  end

  create_table "kpi_readings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kpi_id", null: false
    t.datetime "measured_at", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 12, scale: 2, null: false
    t.index ["tenant_id", "kpi_id", "measured_at"], name: "index_kpi_readings_on_tenant_id_and_kpi_id_and_measured_at"
  end

  create_table "kpis", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "direction", default: "up", null: false
    t.string "name", null: false
    t.decimal "target_value", precision: 12, scale: 2
    t.string "tenant_id", null: false
    t.string "unit"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_kpis_on_tenant_id_and_name"
  end

  create_table "order_lines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "line_cents", default: 0
    t.string "name"
    t.bigint "order_id", null: false
    t.integer "quantity", default: 0
    t.string "sku"
    t.string "tenant_id", null: false
    t.integer "unit_cents", default: 0
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "order_id"], name: "index_order_lines_on_tenant_id_and_order_id"
    t.index ["tenant_id", "sku"], name: "index_order_lines_on_tenant_id_and_sku"
  end

  create_table "orders", force: :cascade do |t|
    t.string "channel"
    t.datetime "created_at", null: false
    t.string "currency", default: "USD"
    t.bigint "customer_id"
    t.string "fulfillment_status", default: "pending", null: false
    t.integer "gross_cents", default: 0
    t.integer "line_items", default: 0
    t.string "location_id"
    t.datetime "occurred_at", null: false
    t.string "order_number"
    t.string "shipping_address1"
    t.string "shipping_address2"
    t.string "shipping_city"
    t.string "shipping_country"
    t.string "shipping_name"
    t.string "shipping_phone"
    t.string "shipping_province"
    t.string "shipping_zip"
    t.string "source", null: false
    t.string "source_order_id", null: false
    t.string "status", null: false
    t.integer "tax_cents", default: 0
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "customer_id"], name: "index_orders_on_tenant_id_and_customer_id"
    t.index ["tenant_id", "occurred_at"], name: "index_orders_on_tenant_id_and_occurred_at"
    t.index ["tenant_id", "source", "source_order_id"], name: "index_orders_on_tenant_id_and_source_and_source_order_id", unique: true
    t.index ["tenant_id", "status"], name: "index_orders_on_tenant_id_and_status"
  end

  create_table "payments", force: :cascade do |t|
    t.integer "amount_cents", default: 0
    t.datetime "created_at", null: false
    t.string "method", null: false
    t.bigint "order_id", null: false
    t.datetime "paid_at", null: false
    t.string "reference"
    t.string "status", default: "completed"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "order_id"], name: "index_payments_on_tenant_id_and_order_id"
    t.index ["tenant_id", "paid_at"], name: "index_payments_on_tenant_id_and_paid_at"
  end

  create_table "pos_sessions", force: :cascade do |t|
    t.integer "card_sales_cents", default: 0
    t.integer "cash_sales_cents", default: 0
    t.datetime "closed_at"
    t.integer "counted_cash_cents"
    t.datetime "created_at", null: false
    t.integer "expected_cash_cents"
    t.integer "gift_sales_cents", default: 0
    t.string "location_id"
    t.string "name", null: false
    t.text "notes"
    t.datetime "opened_at", null: false
    t.integer "opening_cash_cents", default: 0
    t.string "status", default: "open", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_id"
    t.integer "variance_cents"
    t.index ["tenant_id", "opened_at"], name: "index_pos_sessions_on_tenant_id_and_opened_at"
    t.index ["tenant_id", "status"], name: "index_pos_sessions_on_tenant_id_and_status"
  end

  create_table "projects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.date "due_on"
    t.string "name", null: false
    t.string "owner_id"
    t.string "status", default: "planned", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "owner_id"], name: "index_projects_on_tenant_id_and_owner_id"
    t.index ["tenant_id", "status"], name: "index_projects_on_tenant_id_and_status"
  end

  create_table "role_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "permission", null: false
    t.string "role", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "role", "permission"], name: "index_role_permissions_on_tenant_id_and_role_and_permission", unique: true
    t.index ["tenant_id", "role"], name: "index_role_permissions_on_tenant_id_and_role"
  end

  create_table "settings", force: :cascade do |t|
    t.string "key", null: false
    t.string "tenant_id"
    t.datetime "updated_at"
    t.string "value"
    t.index ["key", "tenant_id"], name: "index_settings_on_key_and_tenant_id", unique: true
  end

  create_table "shops", force: :cascade do |t|
    t.string "access_scopes"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "refresh_token"
    t.datetime "refresh_token_expires_at"
    t.string "shopify_domain", null: false
    t.string "shopify_token", null: false
    t.datetime "updated_at", null: false
    t.index ["shopify_domain"], name: "index_shops_on_shopify_domain", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "tasks", force: :cascade do |t|
    t.string "assignee_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.date "due_on"
    t.string "priority", default: "medium"
    t.string "project_id"
    t.string "status", default: "todo", null: false
    t.string "tenant_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "assignee_id"], name: "index_tasks_on_tenant_id_and_assignee_id"
    t.index ["tenant_id", "project_id"], name: "index_tasks_on_tenant_id_and_project_id"
    t.index ["tenant_id", "status"], name: "index_tasks_on_tenant_id_and_status"
  end

  create_table "tenants", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "plan", default: "free"
    t.string "shopify_shop_domain"
    t.string "status", default: "active"
    t.string "subdomain", null: false
    t.datetime "updated_at", null: false
    t.index ["subdomain"], name: "index_tenants_on_subdomain", unique: true
  end

  create_table "user_permissions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "permission", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["tenant_id", "user_id", "permission"], name: "index_user_permissions_on_tenant_id_and_user_id_and_permission", unique: true
    t.index ["tenant_id", "user_id"], name: "index_user_permissions_on_tenant_id_and_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "access_scopes", default: "", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "dashboard_config"
    t.string "email"
    t.datetime "expires_at"
    t.string "name"
    t.string "password_digest"
    t.string "role", default: "admin"
    t.string "shopify_domain"
    t.string "shopify_token"
    t.bigint "shopify_user_id"
    t.string "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["shopify_user_id"], name: "index_users_on_shopify_user_id", unique: true
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
