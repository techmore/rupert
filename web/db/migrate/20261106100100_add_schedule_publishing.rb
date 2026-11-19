# frozen_string_literal: true

# Scheduling: published weeks, open shifts (no employee yet), templates, availability, blackout
# dates and shift trades. `scheduled_shifts.employee_id` becomes nullable for open shifts; every
# existing row keeps its employee.
class AddSchedulePublishing < ActiveRecord::Migration[8.1]
  # SQLite rewrites the table for defaults anyway; these tables are small and the app is single-writer.
  def change
    safety_assured do
      change_column_null :scheduled_shifts, :employee_id, true
      add_column :scheduled_shifts, :published_at, :datetime
      add_column :scheduled_shifts, :position_id, :bigint
      add_column :scheduled_shifts, :break_minutes, :integer, default: 0, null: false
      add_column :scheduled_shifts, :created_by_id, :bigint
      add_column :scheduled_shifts, :last_changed_at, :datetime
      add_column :scheduled_shifts, :cancelled_at, :datetime
      add_index :scheduled_shifts, %i[tenant_id employee_id published_at], name: 'idx_scheduled_shift_published'

      create_table :schedule_templates do |t|
        t.string :tenant_id, null: false
        t.string :location_id
        t.string :name, null: false
        t.bigint :created_by_id
        t.timestamps
      end
      add_index :schedule_templates, %i[tenant_id name], unique: true

      create_table :schedule_template_shifts do |t|
        t.string :tenant_id, null: false
        t.bigint :schedule_template_id, null: false
        t.integer :weekday, null: false
        t.integer :start_minute, null: false
        t.integer :end_minute, null: false
        t.bigint :employee_id
        t.bigint :position_id
        t.string :role_label
        t.integer :break_minutes, default: 0, null: false
        t.timestamps
      end
      add_index :schedule_template_shifts, :schedule_template_id

      create_table :schedule_publications do |t|
        t.string :tenant_id, null: false
        t.string :location_id
        t.date :week_start, null: false
        t.datetime :published_at, null: false
        t.bigint :published_by_id
        t.integer :shift_count, default: 0, null: false
        t.text :notice_json
        t.timestamps
      end
      add_index :schedule_publications, %i[tenant_id location_id week_start], name: 'idx_schedule_publication_week'

      create_table :employee_availabilities do |t|
        t.string :tenant_id, null: false
        t.bigint :employee_id, null: false
        t.integer :weekday, null: false
        t.integer :start_minute, default: 0, null: false
        t.integer :end_minute, default: 1440, null: false
        t.string :kind, default: 'unavailable', null: false
        t.string :note
        t.timestamps
      end
      add_index :employee_availabilities, %i[tenant_id employee_id weekday], name: 'idx_availability_employee_day'

      create_table :blackout_dates do |t|
        t.string :tenant_id, null: false
        t.string :location_id
        t.date :starts_on, null: false
        t.date :ends_on, null: false
        t.string :reason, null: false
        t.bigint :created_by_id
        t.timestamps
      end
      add_index :blackout_dates, %i[tenant_id starts_on ends_on]

      create_table :shift_trades do |t|
        t.string :tenant_id, null: false
        t.bigint :scheduled_shift_id, null: false
        t.string :kind, null: false
        t.bigint :from_employee_id
        t.bigint :to_employee_id
        t.bigint :counter_shift_id
        t.string :status, default: 'open', null: false
        t.text :note
        t.bigint :requested_by_id
        t.datetime :accepted_at
        t.bigint :reviewed_by_id
        t.datetime :reviewed_at
        t.text :review_note
        t.text :checks_json
        t.timestamps
      end
      add_index :shift_trades, %i[tenant_id status]
      add_index :shift_trades, %i[scheduled_shift_id status]
      add_index :shift_trades, %i[tenant_id to_employee_id status], name: 'idx_shift_trade_to'
      add_index :shift_trades, %i[tenant_id from_employee_id status], name: 'idx_shift_trade_from'

      add_column :leave_requests, :review_note, :text
      add_column :leave_requests, :request_key, :string
      add_index :leave_requests, %i[tenant_id request_key], unique: true, where: 'request_key IS NOT NULL'
    end
  end
end
