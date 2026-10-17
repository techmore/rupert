# frozen_string_literal: true

class AddDemoReviewToTimesheets < ActiveRecord::Migration[8.1]
  def change
    add_column :timesheets, :demo, :boolean, default: false, null: false
    add_reference :timesheets, :assigned_reviewer
  end
end
