# frozen_string_literal: true

# Manager workstream of time & pay (docs/time-and-pay/DECISIONS.md). Additive only.
#
# - pay_period_adjustments: hours or money recorded against an open period for something that
#   belongs to an earlier, locked period (a late correction, a missed tip). Never edits history.
# - leave_accruals: a ledger explaining every change to LeaveBalance#accrued_hours (daily sick
#   accrual per hour worked, the annual vacation grant, year-end carry-over caps).
# - employees.sick_accrued_through: watermark for the accrual job so hours are counted once.
class AddPayPeriodAdjustmentsAndLeaveAccruals < ActiveRecord::Migration[8.1]
  def change
    safety_assured do
      create_table :pay_period_adjustments do |t|
        t.string :tenant_id, null: false
        t.bigint :pay_period_id, null: false
        t.bigint :employee_id, null: false
        t.string :kind, null: false
        t.decimal :hours, precision: 7, scale: 2
        t.integer :amount_cents
        t.text :note, null: false
        t.bigint :created_by_id
        t.timestamps
      end
      add_index :pay_period_adjustments, %i[tenant_id pay_period_id]
      add_index :pay_period_adjustments, %i[tenant_id employee_id]

      create_table :leave_accruals do |t|
        t.string :tenant_id, null: false
        t.bigint :employee_id, null: false
        t.string :leave_type, null: false
        t.decimal :hours, precision: 7, scale: 2, null: false
        t.string :reason, null: false
        t.date :period_start
        t.date :period_end
        t.integer :year, null: false
        t.timestamps
      end
      add_index :leave_accruals, %i[tenant_id employee_id leave_type year], name: 'idx_leave_accrual_employee_year'

      add_column :employees, :sick_accrued_through, :datetime
      add_column :employees, :vacation_granted_for_year, :integer
    end
  end
end
