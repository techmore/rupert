# frozen_string_literal: true

module People
  # One day's hours on a timesheet, by work type.
  class TimesheetEntry < ApplicationRecord
    include TenantScoped

    self.table_name = "timesheet_entries"

    WORK_TYPES = ["regular", "overtime", "pto", "holiday"].freeze

    belongs_to :timesheet, class_name: "People::Timesheet"

    validates :worked_on, presence: true
    validates :hours, numericality: { greater_than: 0, less_than_or_equal_to: 24 }
    validates :work_type, inclusion: { in: WORK_TYPES }

    enum :work_type, WORK_TYPES.index_by(&:itself), prefix: true

    scope :ordered, -> { order(:worked_on) }
  end
end
