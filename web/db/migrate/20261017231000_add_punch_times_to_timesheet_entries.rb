# frozen_string_literal: true

class AddPunchTimesToTimesheetEntries < ActiveRecord::Migration[8.1]
  class Entry < ActiveRecord::Base
    self.table_name = 'timesheet_entries'
  end

  class Sheet < ActiveRecord::Base
    self.table_name = 'timesheets'
  end

  def up
    add_column :timesheet_entries, :clocked_in_at, :datetime
    add_column :timesheet_entries, :break_started_at, :datetime
    add_column :timesheet_entries, :break_ended_at, :datetime
    add_column :timesheet_entries, :clocked_out_at, :datetime

    Entry.reset_column_information
    Sheet.where(demo: true).find_each do |sheet|
      Entry.where(timesheet_id: sheet.id).find_each do |entry|
        clocked_in_at = entry.worked_on.in_time_zone.change(hour: 9)
        break_started_at = clocked_in_at.change(hour: 12)
        break_ended_at = break_started_at + 30.minutes
        clocked_out_at = clocked_in_at + entry.hours.to_d.hours + 30.minutes
        entry.update_columns(
          clocked_in_at: clocked_in_at,
          break_started_at: break_started_at,
          break_ended_at: break_ended_at,
          clocked_out_at: clocked_out_at
        )
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Demo punch times must be retained with the review record.'
  end
end
