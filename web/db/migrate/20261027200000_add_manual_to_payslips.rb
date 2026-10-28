# frozen_string_literal: true

# Marks payslips an owner added by hand (bonus, commission, off-cycle) so regenerating a draft pay run from approved
# timesheets rebuilds only the generated ones instead of deleting the manual ones.
class AddManualToPayslips < ActiveRecord::Migration[8.1]
  def change
    safety_assured { add_column :payslips, :manual, :boolean, null: false, default: false }
  end
end
