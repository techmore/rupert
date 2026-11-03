# frozen_string_literal: true

# F70: compliant ring-up guardrails and event mode.
#
# - An owner-approved catalog per store (compliant name, approved category,
#   per-tender eligibility) layered over the store's native C-Trax variants.
# - Certificates of analysis per approved product and batch.
# - A per-store policy that locks the register to the approved catalog.
# - An append-only compliance audit trail (catalog edits, blocked sales,
#   manager PIN overrides, event open/close).
# - Event (show / pop-up) mode: a frozen, owner-picked item list with preset
#   prices, idempotent sales and end-of-event reconciliation.
class CreateComplianceGuardrails < ActiveRecord::Migration[8.1]
  def change
    create_table :compliance_categories do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.boolean :card_eligible, null: false, default: false
      t.boolean :prohibited, null: false, default: false
      t.text :notes
      t.timestamps
      t.index %i[tenant_id name], unique: true, name: 'idx_compliance_categories_name'
    end

    create_table :compliance_catalog_items do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.references :compliance_category, null: false
      t.string :source, null: false, default: 'ctrax'
      t.string :source_variant_id, null: false
      t.string :source_name
      t.string :sku
      t.string :compliant_name, null: false
      t.string :receipt_name
      t.string :status, null: false, default: 'approved'
      t.boolean :card_eligible, null: false, default: false
      t.boolean :cash_eligible, null: false, default: true
      t.boolean :age_restricted, null: false, default: true
      t.boolean :coa_required, null: false, default: true
      t.decimal :thc_mg_per_container, precision: 10, scale: 3
      t.integer :approved_price_cents
      t.integer :approved_by_id
      t.datetime :approved_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[tenant_id location_id source source_variant_id], unique: true, name: 'idx_compliance_items_source'
      t.foreign_key 'Location', column: :location_id
      t.foreign_key :compliance_categories
      t.check_constraint "status IN ('approved', 'suspended')", name: 'compliance_item_status'
    end

    create_table :certificates_of_analysis do |t|
      t.string :tenant_id, null: false
      t.references :compliance_catalog_item, null: false
      t.string :batch
      t.string :lab_name, null: false
      t.string :report_identifier
      t.date :tested_on, null: false
      t.date :expires_on
      t.string :document_url, null: false
      t.string :status, null: false, default: 'current'
      t.integer :added_by_id
      t.integer :withdrawn_by_id
      t.datetime :withdrawn_at
      t.text :withdrawal_reason
      t.timestamps
      t.check_constraint "status IN ('current', 'withdrawn')", name: 'coa_status'
      t.foreign_key :compliance_catalog_items
    end

    create_table :compliance_policies do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false
      t.boolean :locked_catalog, null: false, default: false
      t.integer :coa_max_age_days, null: false, default: 365
      t.integer :updated_by_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[tenant_id location_id], unique: true, name: 'idx_compliance_policies_location'
      t.foreign_key 'Location', column: :location_id
    end

    create_table :compliance_events do |t|
      t.string :tenant_id, null: false
      t.string :location_id
      t.integer :user_id
      t.string :actor_name
      t.integer :approver_id
      t.string :approver_name
      t.string :action, null: false
      t.string :subject_type
      t.string :subject_id
      t.string :subject_label
      t.text :reason
      t.text :details_json
      t.integer :pos_checkout_id
      t.integer :pos_event_id
      t.timestamps
      t.index %i[tenant_id created_at], name: 'idx_compliance_events_time'
      t.index %i[tenant_id action created_at], name: 'idx_compliance_events_action'
      t.index %i[tenant_id pos_event_id], name: 'idx_compliance_events_event'
    end

    create_table :pos_events do |t|
      t.string :tenant_id, null: false
      t.string :location_id, null: false, index: true
      t.string :name, null: false
      t.string :venue
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.string :status, null: false, default: 'draft'
      t.integer :tax_rate_bps, null: false, default: 0
      t.integer :opening_float_cents, null: false, default: 0
      t.integer :counted_cash_cents
      t.integer :terminal_card_total_cents
      t.text :staff_user_ids_json
      t.text :checklist_json
      t.text :close_notes
      t.integer :created_by_id
      t.integer :opened_by_id
      t.datetime :opened_at
      t.integer :closed_by_id
      t.datetime :closed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.check_constraint "status IN ('draft', 'open', 'closed')", name: 'pos_event_status'
      t.foreign_key 'Location', column: :location_id
    end

    create_table :pos_event_items do |t|
      t.string :tenant_id, null: false
      t.references :pos_event, null: false
      t.references :compliance_catalog_item, null: false
      t.string :name, null: false
      t.string :category_name
      t.integer :price_cents, null: false
      t.boolean :card_eligible, null: false, default: false
      t.boolean :age_restricted, null: false, default: true
      t.string :coa_url
      t.date :coa_expires_on
      t.integer :loaded_quantity
      t.integer :counted_remaining
      t.integer :position, null: false, default: 0
      t.datetime :pulled_at
      t.integer :pulled_by_id
      t.timestamps
      t.index %i[pos_event_id compliance_catalog_item_id], unique: true, name: 'idx_pos_event_items_unique'
      t.foreign_key :pos_events
      t.foreign_key :compliance_catalog_items
    end

    create_table :pos_event_sales do |t|
      t.string :tenant_id, null: false
      t.references :pos_event, null: false, index: false
      t.references :user, null: false
      t.string :client_sale_id, null: false
      t.string :tender, null: false
      t.text :lines_json, null: false
      t.integer :subtotal_cents, null: false
      t.integer :tax_cents, null: false
      t.integer :total_cents, null: false
      t.integer :cash_received_cents
      t.integer :change_cents
      t.boolean :id_checked, null: false, default: false
      t.integer :override_by_id
      t.text :override_reason
      t.text :flags_json
      t.datetime :occurred_at, null: false
      t.integer :order_id
      t.timestamps
      t.index %i[pos_event_id client_sale_id], unique: true, name: 'idx_pos_event_sales_client'
      t.check_constraint "tender IN ('cash', 'card_terminal')", name: 'pos_event_sale_tender'
      t.foreign_key :pos_events
    end

    add_column :users, :pos_override_pin_digest, :string
    add_column :users, :pos_override_pin_set_at, :datetime

    add_column :pos_checkouts, :id_checked, :boolean
    add_column :pos_checkouts, :compliance_override_by_id, :integer
    add_column :pos_checkouts, :compliance_override_reason, :text
    add_column :pos_checkouts, :compliance_issues_json, :text
  end
end
