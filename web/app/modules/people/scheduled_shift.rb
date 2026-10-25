# frozen_string_literal: true

module People
  # A planned shift for one employee. Not a record of hours worked.
  class ScheduledShift < ApplicationRecord
    include TenantScoped

    self.table_name = 'scheduled_shifts'

    # Planning warnings only (#469); neither ever blocks a save. Hours are planned
    # hours in a seven-day pay week (EmployeePayWeek.week_start, Thursday unless the pay rules say otherwise), not overtime pay.
    PLANNED_HOURS_LIMIT = 40
    MIN_REST_HOURS = 10

    belongs_to :employee, class_name: 'People::Employee'
    # Optional store (#469). Clock punches carry no store, so worked hours are never split by it.
    belongs_to :location, class_name: 'Location', optional: true

    validates :starts_at, :ends_at, presence: true
    validates :role_label, length: { maximum: 80 }
    validates :notes, length: { maximum: 2000 }
    validate :employee_in_workspace
    validate :location_in_workspace
    validate :ordered_interval
    validate :non_overlapping_interval

    scope :chronological, -> { order(:starts_at, :id) }
    scope :between, lambda { |from, to|
      where('starts_at < ? AND ends_at > ?', (to + 1).in_time_zone, from.in_time_zone)
    }

    def hours
      return 0 if starts_at.nil? || ends_at.nil?

      (ends_at - starts_at) / 3600.0
    end

    # Hours of this shift that fall between two times (a shift can cross midnight
    # into the next pay week).
    def hours_within(from, to)
      [([ends_at, to].min - [starts_at, from].max) / 3600.0, 0].max
    end

    # Planned hours per pay-week start for one person, for each pay week touched by `days`.
    def self.pay_week_hours(employee_id, days)
      days.map { |day| EmployeePayWeek.week_start(day) }.uniq.index_with do |start|
        from = start.in_time_zone
        to = (start + 7).in_time_zone
        between(start, start + 6).where(employee_id: employee_id).sum { |shift| shift.hours_within(from, to) }
      end
    end

    # The pay weeks this shift touches where the person is planned over the limit.
    def pay_weeks_over_limit
      return {} if starts_at.nil? || ends_at.nil? || employee_id.blank?

      self.class.pay_week_hours(employee_id, [starts_at.to_date, ends_at.to_date]).select { |_start, total| total > PLANNED_HOURS_LIMIT }
    end

    # Hours between the end of the person's previous shift and the start of this
    # one, and between this one and their next, when either is shorter than the minimum.
    def short_rests
      return [] if starts_at.nil? || ends_at.nil? || employee_id.blank?

      others = self.class.where(employee_id: employee_id).where.not(id: id)
      before = others.where('ends_at <= ?', starts_at).order(ends_at: :desc).first
      after = others.where('starts_at >= ?', ends_at).order(:starts_at).first
      [before && ((starts_at - before.ends_at) / 3600.0), after && ((after.starts_at - ends_at) / 3600.0)]
        .compact.select { |gap| gap < MIN_REST_HOURS }
    end

    # Approved leave for this person on any calendar day the shift touches.
    # A warning only: a manager may still schedule someone on leave.
    def approved_leave
      return People::LeaveRequest.none if starts_at.nil? || ends_at.nil? || employee_id.blank?

      People::LeaveRequest.where(employee_id: employee_id, status: 'approved')
        .where('starts_on <= ? AND ends_on >= ?', ends_at.to_date, starts_at.to_date)
    end

    # Copies the week before `week` (a Monday) forward seven days. Wall-clock
    # times are kept across a DST change. Shifts that would overlap one already
    # planned, or belong to someone no longer active, are skipped.
    def self.copy_week_forward(week)
      copied = []
      skipped = 0
      transaction do
        between(week - 7, week - 1).where('starts_at >= ?', (week - 7).in_time_zone).chronological.includes(:employee).each do |source|
          shift = new(employee: source.employee, starts_at: source.starts_at + 7.days, ends_at: source.ends_at + 7.days,
            role_label: source.role_label, notes: source.notes, location_id: source.location_id)
          if source.employee&.status == 'active' && shift.save
            copied << shift
          else
            skipped += 1
          end
        end
      end
      [copied, skipped]
    end

    def time_label
      "#{starts_at.strftime('%-l:%M %p')} – #{ends_at.strftime('%-l:%M %p')}"
    end

    private

    def employee_in_workspace
      errors.add(:employee, 'must belong to this workspace') unless employee && employee.tenant_id == tenant_id
    end

    def location_in_workspace
      return if location_id.blank?

      errors.add(:location, 'must be a store in this workspace') unless Location.exists?(id: location_id)
    end

    def ordered_interval
      return if starts_at.nil? || ends_at.nil?

      errors.add(:ends_at, 'must be after the start') if ends_at <= starts_at
      errors.add(:ends_at, 'cannot make a shift longer than 24 hours') if ends_at > starts_at + 24.hours
    end

    def non_overlapping_interval
      return if starts_at.nil? || ends_at.nil? || employee_id.blank?

      overlap = self.class.where(employee_id: employee_id).where.not(id: id).where('starts_at < ? AND ends_at > ?', ends_at, starts_at)
      errors.add(:base, 'This overlaps another scheduled shift for this person') if overlap.exists?
    end
  end
end
