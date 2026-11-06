# frozen_string_literal: true

# Time and pay foundation (docs/time-and-pay/ARCHITECTURE.md). Every change is additive:
# new nullable columns with defaults and new tables, so a code rollback leaves the data usable.
#
# - A worker's 4-6 digit clock PIN (digest only) for the POS clock and the counter tablet.
# - Which store, which device and which channel a punch came from; meal and rest breaks on a punch.
# - Trusted store devices: a browser/tablet a manager registered so PIN punches work without a sign-in.
class AddTimeClockContext < ActiveRecord::Migration[8.1]
  # SQLite rewrites the table for defaults anyway; these tables are small and the app is single-writer.
  def change
    safety_assured do
      add_column :employees, :pin_digest, :string
      add_column :employees, :pin_set_at, :datetime
      add_column :employees, :pin_failed_count, :integer, default: 0, null: false
      add_column :employees, :pin_locked_until, :datetime
      add_column :employees, :locale, :string
      add_column :employees, :tip_eligible, :boolean, default: true, null: false
      add_column :employees, :location_ids_json, :text

      add_column :clock_shifts, :location_id, :string
      add_column :clock_shifts, :source, :string, default: 'web', null: false
      add_column :clock_shifts, :device_label, :string
      add_column :clock_shifts, :register_name, :string
      add_column :clock_shifts, :scheduled_shift_id, :bigint
      add_column :clock_shifts, :auto_closed_at, :datetime
      add_index :clock_shifts, %i[tenant_id location_id started_at], name: 'idx_clock_shift_location'

      add_column :clock_corrections, :original_breaks_json, :text
      add_column :clock_corrections, :proposed_breaks_json, :text
      add_column :clock_corrections, :review_note, :text

      create_table :clock_breaks do |t|
        t.string :tenant_id, null: false
        t.bigint :clock_shift_id, null: false
        t.string :kind, null: false, default: 'rest'
        t.boolean :paid, null: false, default: true
        t.datetime :started_at, null: false
        t.datetime :ended_at
        t.timestamps
      end
      add_index :clock_breaks, %i[clock_shift_id started_at]
      add_index :clock_breaks, %i[tenant_id clock_shift_id], name: 'idx_clock_break_open', unique: true, where: 'ended_at IS NULL'

      create_table :clock_devices do |t|
        t.string :tenant_id, null: false
        t.string :location_id
        t.string :name, null: false
        t.string :token_digest, null: false
        t.bigint :registered_by_id
        t.datetime :last_seen_at
        t.datetime :revoked_at
        t.timestamps
      end
      add_index :clock_devices, %i[tenant_id token_digest], unique: true
    end
  end
end
