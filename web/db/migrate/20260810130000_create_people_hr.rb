# frozen_string_literal: true

# The People / HR module set: employee records, org structure, time tracking,
# leave & PTO, and payroll. All tables are tenant-scoped bigint records like the
# rest of the canonical ERP schema.
class CreatePeopleHr < ActiveRecord::Migration[8.1]
  def change
    create_table(:departments) do |t|
      t.string(:tenant_id, null: false)
      t.string(:name, null: false)
      t.string(:code)
      t.text(:description)
      t.timestamps

      t.index([:tenant_id, :name], unique: true)
    end

    create_table(:positions) do |t|
      t.string(:tenant_id, null: false)
      t.string(:name, null: false)
      t.bigint(:department_id)
      t.string(:pay_grade)
      t.text(:description)
      t.timestamps

      t.index([:tenant_id, :department_id])
      t.index([:tenant_id, :name])
    end

    create_table(:employees) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:user_id)
      t.bigint(:department_id)
      t.bigint(:position_id)
      t.string(:employee_number)
      t.string(:first_name, null: false)
      t.string(:last_name, null: false)
      t.string(:legal_name)
      t.string(:email)
      t.string(:phone)
      t.text(:address)
      t.date(:date_of_birth)
      t.date(:hire_date)
      t.date(:termination_date)
      t.string(:employment_type, default: "full_time")
      t.string(:status, null: false, default: "active")
      t.string(:emergency_contact_name)
      t.string(:emergency_contact_phone)
      t.text(:notes)
      t.timestamps

      t.index([:tenant_id, :employee_number], unique: true)
      t.index([:tenant_id, :department_id])
      t.index([:tenant_id, :position_id])
      t.index([:tenant_id, :user_id])
      t.index([:tenant_id, :status])
    end

    add_reference(:departments, :manager, type: :bigint, index: false, foreign_key: { to_table: :employees }, null: true)

    create_table(:pay_rates) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:employee_id, null: false)
      t.string(:pay_type, null: false, default: "hourly")
      t.integer(:hourly_rate_cents, null: false, default: 0)
      t.integer(:annual_salary_cents, null: false, default: 0)
      t.string(:pay_frequency, null: false, default: "biweekly")
      t.date(:effective_on, null: false)
      t.date(:ended_on)
      t.timestamps

      t.index([:tenant_id, :employee_id])
      t.index([:tenant_id, :effective_on])
    end

    create_table(:timesheets) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:employee_id, null: false)
      t.date(:period_start, null: false)
      t.date(:period_end, null: false)
      t.string(:status, null: false, default: "draft")
      t.text(:notes)
      t.bigint(:reviewed_by)
      t.datetime(:reviewed_at)
      t.timestamps

      t.index([:tenant_id, :employee_id, :period_start], unique: true)
      t.index([:tenant_id, :status])
    end

    create_table(:timesheet_entries) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:timesheet_id, null: false)
      t.date(:worked_on, null: false)
      t.decimal(:hours, precision: 6, scale: 2, null: false, default: 0)
      t.string(:work_type, null: false, default: "regular")
      t.timestamps

      t.index([:tenant_id, :timesheet_id])
    end

    create_table(:leave_balances) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:employee_id, null: false)
      t.string(:leave_type, null: false)
      t.integer(:year, null: false)
      t.decimal(:accrued_hours, precision: 6, scale: 2, null: false, default: 0)
      t.decimal(:used_hours, precision: 6, scale: 2, null: false, default: 0)
      t.timestamps

      t.index([:tenant_id, :employee_id, :leave_type, :year], unique: true)
    end

    create_table(:leave_requests) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:employee_id, null: false)
      t.string(:leave_type, null: false)
      t.string(:status, null: false, default: "requested")
      t.date(:starts_on, null: false)
      t.date(:ends_on, null: false)
      t.decimal(:hours, precision: 6, scale: 2)
      t.text(:reason)
      t.bigint(:reviewed_by)
      t.datetime(:reviewed_at)
      t.timestamps

      t.index([:tenant_id, :employee_id, :status])
      t.index([:tenant_id, :status])
    end

    create_table(:pay_runs) do |t|
      t.string(:tenant_id, null: false)
      t.string(:name, null: false)
      t.date(:period_start, null: false)
      t.date(:period_end, null: false)
      t.string(:status, null: false, default: "draft")
      t.date(:paid_on)
      t.integer(:total_gross_cents, null: false, default: 0)
      t.integer(:total_net_cents, null: false, default: 0)
      t.text(:notes)
      t.timestamps

      t.index([:tenant_id, :period_start])
      t.index([:tenant_id, :status])
    end

    create_table(:payslips) do |t|
      t.string(:tenant_id, null: false)
      t.bigint(:pay_run_id, null: false)
      t.bigint(:employee_id, null: false)
      t.bigint(:pay_rate_id)
      t.decimal(:hours, precision: 6, scale: 2, null: false, default: 0)
      t.integer(:gross_cents, null: false, default: 0)
      t.integer(:deductions_cents, null: false, default: 0)
      t.integer(:net_cents, null: false, default: 0)
      t.text(:notes)
      t.timestamps

      t.index([:tenant_id, :pay_run_id])
      t.index([:tenant_id, :employee_id])
    end
  end
end
