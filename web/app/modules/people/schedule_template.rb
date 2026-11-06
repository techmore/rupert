# frozen_string_literal: true

module People
  # A reusable week: shifts by weekday and time, optionally pinned to a person or position.
  # Applying a template to a week creates planned shifts (open ones when no person is pinned).
  class ScheduleTemplate < ApplicationRecord
    include TenantScoped

    self.table_name = 'schedule_templates'

    belongs_to :location, optional: true
    belongs_to :created_by, class_name: 'User', optional: true
    has_many :shifts, class_name: 'People::ScheduleTemplateShift', foreign_key: :schedule_template_id, dependent: :destroy, inverse_of: :template

    validates :name, presence: true, length: { maximum: 80 }, uniqueness: { scope: :tenant_id }

    scope :ordered, -> { order(:name) }

    # Saves the shifts of the week starting `week_start` (a Date) as this template's shifts.
    def capture_week!(week_start, location_id: nil)
      scope = People::ScheduledShift.between(week_start, week_start + 6).where(cancelled_at: nil)
      scope = scope.where(location_id: location_id) if location_id.present?
      transaction do
        shifts.delete_all
        scope.chronological.each do |shift|
          local_start = shift.starts_at.in_time_zone(BusinessClock.zone(tenant: Current.tenant, location: shift.location))
          local_end = shift.ends_at.in_time_zone(local_start.time_zone)
          shifts.create!(weekday: local_start.wday, start_minute: (local_start.hour * 60) + local_start.min,
            end_minute: ((local_end.to_date - local_start.to_date).to_i * 1440) + (local_end.hour * 60) + local_end.min,
            employee_id: shift.employee_id, position_id: shift.position_id, role_label: shift.role_label, break_minutes: shift.break_minutes)
        end
      end
      self
    end

    # Creates planned shifts for the week starting `week_start`. Shifts that would overlap an existing
    # one for the same person, or whose person is no longer active, are skipped. Returns [created, skipped].
    def apply_to_week!(week_start, location_id: nil, created_by: Current.user)
      zone = BusinessClock.zone(tenant: Current.tenant, location: location_id && Location.find_by(id: location_id))
      created = []
      skipped = 0
      transaction do
        shifts.order(:weekday, :start_minute).each do |line|
          day = week_start + ((line.weekday - week_start.wday) % 7)
          starts_at = zone.local(day.year, day.month, day.day) + line.start_minute.minutes
          ends_at = zone.local(day.year, day.month, day.day) + line.end_minute.minutes
          employee = line.employee_id && People::Employee.find_by(id: line.employee_id, status: 'active')
          if line.employee_id && employee.nil?
            skipped += 1
            next
          end
          shift = People::ScheduledShift.new(employee: employee, starts_at: starts_at, ends_at: ends_at, role_label: line.role_label,
            position_id: line.position_id, break_minutes: line.break_minutes, location_id: location_id.presence || self.location_id, created_by: created_by)
          shift.save ? created << shift : skipped += 1
        end
      end
      [created, skipped]
    end
  end

  class ScheduleTemplateShift < ApplicationRecord
    include TenantScoped

    self.table_name = 'schedule_template_shifts'

    belongs_to :template, class_name: 'People::ScheduleTemplate', foreign_key: :schedule_template_id, inverse_of: :shifts
    belongs_to :employee, class_name: 'People::Employee', optional: true
    belongs_to :position, class_name: 'People::Position', optional: true

    validates :weekday, inclusion: { in: 0..6 }
    validates :start_minute, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 1440 }
    validates :end_minute, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2880 }
    validate { errors.add(:end_minute, 'must be after the start') if start_minute && end_minute && end_minute <= start_minute }
  end
end
