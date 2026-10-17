class CreateEmployeeEarningsPeriods < ActiveRecord::Migration[8.0]
  def change
    create_table :employee_earnings_periods do |t|
      t.string :tenant_id, null: false
      t.references :employee, null: false, foreign_key: true
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.decimal :hours, precision: 8, scale: 2, null: false
      %i[base tips store_commission online_commission bonus].each { |name| t.integer "#{name}_cents", null: false, default: 0 }
      t.datetime :reviewed_at, null: false
      t.timestamps
    end
    add_index :employee_earnings_periods, [:tenant_id, :employee_id, :period_start, :period_end], unique: true, name: 'idx_employee_earnings_period'
  end
end
