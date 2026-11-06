# frozen_string_literal: true

# Tips ledger, pay-period locks, push devices and the Dejavoo FEED clerk/terminal fields.
#
# tip_allocations is the one place a tip is attributed to a person: card tips from the terminal
# (Dejavoo FEED / Authorize.net settlement), cash tips a worker declares, pool shares and manager
# adjustments. Amounts are signed cents; a refund or void adds a negative row that points back at
# the row it reverses, so history is never rewritten.
class AddTipsAndPayPeriods < ActiveRecord::Migration[8.1]
  # SQLite rewrites the table for defaults anyway; these tables are small and the app is single-writer.
  def change
    safety_assured do
      add_column :dejavoo_feed_events, :performed_by, :string
      add_column :dejavoo_feed_events, :terminal_id, :string
      add_column :dejavoo_feed_events, :invoice_number, :string
      add_column :dejavoo_feed_events, :device_model, :string
      add_column :dejavoo_feed_events, :tip_attributed_at, :datetime

      add_column :authorize_net_transactions, :tip_attributed_at, :datetime

      create_table :tip_allocations do |t|
        t.string :tenant_id, null: false
        t.bigint :employee_id
        t.bigint :clock_shift_id
        t.string :location_id
        t.string :source_kind, null: false
        t.bigint :source_id
        t.string :source_ref
        t.string :tip_method, null: false
        t.string :status, null: false, default: 'estimated'
        t.integer :amount_cents, null: false
        t.integer :gross_tip_cents
        t.integer :share_count
        t.datetime :occurred_at, null: false
        t.date :business_date, null: false
        t.date :pay_period_start
        t.string :settlement_ref
        t.datetime :settled_at
        t.bigint :reverses_id
        t.string :evidence
        t.text :note
        t.bigint :created_by_id
        t.timestamps
      end
      add_index :tip_allocations, %i[tenant_id employee_id business_date], name: 'idx_tip_alloc_employee_day'
      add_index :tip_allocations, %i[tenant_id source_kind source_id], name: 'idx_tip_alloc_source'
      add_index :tip_allocations, %i[tenant_id pay_period_start], name: 'idx_tip_alloc_period'
      add_index :tip_allocations, %i[tenant_id status]

      create_table :pay_periods do |t|
        t.string :tenant_id, null: false
        t.date :starts_on, null: false
        t.date :ends_on, null: false
        t.string :status, default: 'open', null: false
        t.datetime :locked_at
        t.bigint :locked_by_id
        t.datetime :exported_at
        t.bigint :exported_by_id
        t.string :export_sha256
        t.text :totals_json
        t.text :note
        t.timestamps
      end
      add_index :pay_periods, %i[tenant_id starts_on], unique: true

      create_table :push_devices do |t|
        t.string :tenant_id, null: false
        t.bigint :user_id, null: false
        t.string :platform, null: false
        t.text :token, null: false
        t.string :token_digest, null: false
        t.string :environment
        t.string :app_version
        t.text :keys_json
        t.datetime :last_seen_at
        t.datetime :disabled_at
        t.string :failure_reason
        t.timestamps
      end
      add_index :push_devices, %i[tenant_id token_digest], unique: true
      add_index :push_devices, %i[user_id platform]

      add_column :users, :location_ids_json, :text
      add_column :users, :notification_prefs_json, :text
    end
  end
end
