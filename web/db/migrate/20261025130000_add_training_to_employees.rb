# frozen_string_literal: true

# A per-employee "in training" flag with dates (#465). Only the read-only incentives model reads it; real pay does not.
class AddTrainingToEmployees < ActiveRecord::Migration[8.1]
  def change
    # SQLite adds a column with a constant default in place, without rewriting the table.
    safety_assured { add_column :employees, :in_training, :boolean, default: false, null: false }
    add_column :employees, :training_starts_on, :date
    add_column :employees, :training_ends_on, :date
  end
end
