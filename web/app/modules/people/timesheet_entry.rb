# frozen_string_literal: true

module People
  # One day's hours on a timesheet, by work type.
  class TimesheetEntry < ApplicationRecord
    include TenantScoped

    self.table_name = 'timesheet_entries'

    WORK_TYPES = %w[regular overtime pto holiday].freeze

    belongs_to :timesheet, class_name: 'People::Timesheet'

    belongs_to :clock_shift, optional: true
    validates :notes, length: { maximum: 1000 }
    validate :valid_time_record
    validate :valid_punch_times
    validate :square_history_overlap
    validates :worked_on, presence: true
    validates :hours, numericality: { greater_than: 0, less_than_or_equal_to: 24 }
    validates :work_type, inclusion: { in: WORK_TYPES }

    enum :work_type, WORK_TYPES.index_by(&:itself), prefix: true, validate: true

    scope :ordered, -> { order(:worked_on, :id) }

    private

    def valid_punch_times
      punches = [clocked_in_at, break_started_at, break_ended_at, clocked_out_at]
      if punches.any?(&:present?) && punches.any?(&:blank?)
        errors.add(:base, 'Clock in, break out, break in and clock out must all be recorded')
        return
      end
      if timesheet&.demo? && punches.any?(&:blank?)
        errors.add(:base, 'Demo entries must show clock in, break out, break in and clock out')
        return
      end
      return if punches.all?(&:blank?)

      unless punches.each_cons(2).all? { |left, right| left < right }
        errors.add(:base, 'Punch times must be in clock in, break out, break in and clock out order')
        return
      end
      if worked_on && punches.any? { |punch| punch.in_time_zone.to_date != worked_on }
        errors.add(:base, 'Punch times must be on the entry date')
      end
      net_hours = ((clocked_out_at - clocked_in_at - (break_ended_at - break_started_at)) / 1.hour).round(2)
      errors.add(:hours, 'must equal the net punch time') if hours && net_hours != hours.to_d
    end

    def square_history_overlap
      return unless timesheet && worked_on && %w[regular overtime].include?(work_type)

      from = clock_shift&.started_at || worked_on.in_time_zone
      to = clock_shift&.ended_at || (worked_on + 1).in_time_zone
      if SquareTimecard.overlapping(timesheet.employee_id, from, to).exists?
        errors.add(:base, 'Square hours already cover this date or shift. Use non-overlapping clock shifts or request a correction for review.')
      end
    end

    def valid_time_record
      return unless timesheet
      if !timesheet.draft? && (new_record? || has_changes_to_save?)
        errors.add(:base, 'Only draft timesheets can be edited')
      end
      errors.add(:timesheet, 'must belong to this workspace') unless timesheet.tenant_id == tenant_id
      if worked_on && timesheet.period_start && timesheet.period_end
        errors.add(:worked_on, 'must be inside the timesheet period') unless (timesheet.period_start..timesheet.period_end).cover?(worked_on)
        errors.add(:worked_on, 'cannot be in the future') if worked_on > Date.current
      end
      if worked_on && hours
        daily = self.class.joins(:timesheet).where(timesheets: { employee_id: timesheet.employee_id })
          .where(worked_on: worked_on).where.not(id: id).sum(:hours)
        errors.add(:hours, 'would exceed 24 hours for this day') if daily + hours > 24
      end
    end
  end
end
