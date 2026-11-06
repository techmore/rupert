# frozen_string_literal: true

module People
  # When a person can or cannot work, by weekday. Minutes from midnight in the store's zone.
  # 'unavailable' blocks are what the schedule builder warns about; 'preferred' is a hint.
  class EmployeeAvailability < ApplicationRecord
    include TenantScoped

    self.table_name = 'employee_availabilities'

    KINDS = %w[unavailable available preferred].freeze
    WEEKDAYS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

    belongs_to :employee, class_name: 'People::Employee'

    validates :weekday, inclusion: { in: 0..6 }
    validates :kind, inclusion: { in: KINDS }
    validates :start_minute, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 1440 }
    validates :end_minute, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 1440 }
    validates :note, length: { maximum: 120 }
    validate { errors.add(:end_minute, 'must be after the start') if start_minute && end_minute && end_minute <= start_minute }

    scope :ordered, -> { order(:weekday, :start_minute) }

    def weekday_label = WEEKDAYS[weekday]
    def all_day? = start_minute.zero? && end_minute == 1440

    def time_label
      return 'All day' if all_day?

      "#{self.class.minute_label(start_minute)} – #{self.class.minute_label(end_minute)}"
    end

    def self.minute_label(minute)
      Time.utc(2000, 1, 1, minute / 60 % 24, minute % 60).strftime('%-l:%M %p')
    end

    # Unavailable blocks for `employee_id` that overlap a planned shift (local times).
    def self.conflicts_for(employee_id, starts_at, ends_at, zone:)
      local_start = starts_at.in_time_zone(zone)
      local_end = ends_at.in_time_zone(zone)
      where(employee_id: employee_id, kind: 'unavailable').ordered.select do |block|
        day = local_start.to_date
        day += 1 while day <= local_end.to_date && day.wday != block.weekday
        next false if day > local_end.to_date

        block_start = zone.local(day.year, day.month, day.day) + block.start_minute.minutes
        block_end = zone.local(day.year, day.month, day.day) + block.end_minute.minutes
        block_start < ends_at && block_end > starts_at
      end
    end
  end
end
