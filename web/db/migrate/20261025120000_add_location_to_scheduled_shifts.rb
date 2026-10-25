# frozen_string_literal: true

# Optional store on a planned shift (#469), so a schedule can be read per store.
class AddLocationToScheduledShifts < ActiveRecord::Migration[8.1]
  def change
    add_column :scheduled_shifts, :location_id, :string
    add_index :scheduled_shifts, %i[tenant_id location_id starts_at], name: 'idx_scheduled_shift_location'
    add_foreign_key :scheduled_shifts, 'Location', column: :location_id, on_delete: :nullify
  end
end
