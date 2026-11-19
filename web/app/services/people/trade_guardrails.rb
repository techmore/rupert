# frozen_string_literal: true

module People
  # Whether `employee` may take `shift` (a give-away, a swap, or an open-shift pickup). Returns an
  # array of checks; a 'block' stops the trade, a 'warn' is shown to the manager. The same checks run
  # when a colleague accepts and again at approval, so a schedule that changed in between is caught.
  class TradeGuardrails
    Check = Struct.new(:level, :code, :message) do
      def to_h = { 'level' => level, 'code' => code, 'message' => message }
    end

    def self.check(shift, employee, counter_shift: nil)
      new(shift, employee, counter_shift: counter_shift).checks.map(&:to_h)
    end

    def initialize(shift, employee, counter_shift: nil)
      @shift = shift
      @employee = employee
      @counter_shift = counter_shift
      @rules = TimeRules.for(shift.location_id)
      @zone = BusinessClock.zone(tenant: Current.tenant, location: shift.location)
    end

    def checks
      list = []
      list << Check.new('block', 'inactive', "#{@employee.name} is not an active staff member.") unless @employee.active?
      list << Check.new('block', 'double_booked', "#{@employee.name} already has a shift that overlaps this one.") if double_booked?
      list << Check.new('block', 'time_off', "#{@employee.name} has approved time off that day.") if time_off?
      list << Check.new('block', 'notice', "Less than #{plain(@rules.trade_min_notice_hours)} hours before the shift starts.") if short_notice?
      list << Check.new('block', 'overtime', "This would put #{@employee.name} over #{PayRules.current.overtime_threshold_label} hours that week.") if overtime?
      list << Check.new('block', 'position', "This shift needs #{@shift.position&.name}, which #{@employee.name} does not hold.") if position_mismatch?
      list.concat(minor_checks)
      list << Check.new('warn', 'short_rest', "Less than #{plain(@rules.min_rest_between_shifts_hours)} hours rest around this shift.") if short_rest?
      list << Check.new('warn', 'availability', "#{@employee.name} marked this time as unavailable.") if unavailable?
      list << Check.new('warn', 'store', "#{@employee.name} usually works at another store.") if other_store?
      list
    end

    private

    def plain(decimal) = decimal.to_s('F').delete_suffix('.0')

    def excluded_ids = [@shift.id, @counter_shift&.id].compact

    def double_booked?
      People::ScheduledShift.live.where(employee_id: @employee.id).where.not(id: excluded_ids)
        .where('starts_at < ? AND ends_at > ?', @shift.ends_at, @shift.starts_at).exists?
    end

    def time_off?
      People::LeaveRequest.where(employee_id: @employee.id, status: 'approved')
        .where('starts_on <= ? AND ends_on >= ?', @shift.ends_at.to_date, @shift.starts_at.to_date).exists?
    end

    def short_notice?
      @shift.starts_at < Time.current + @rules.trade_min_notice_hours.to_f.hours
    end

    # Planned (without the counter shift) or worked hours in the shift's work week, whichever is
    # larger, plus this shift. Blocks when that crosses the weekly overtime threshold.
    def overtime?
      return false unless @rules.trade_block_overtime?

      week_start = PayRules.current.week_start(@shift.starts_at.to_date)
      from = week_start.in_time_zone
      to = (week_start + 7).in_time_zone
      planned = People::ScheduledShift.live.where(employee_id: @employee.id).where.not(id: excluded_ids)
        .where('starts_at < ? AND ends_at > ?', to, from).sum { |s| s.hours_within(from, to) }
      worked = ClockShift.where(employee_id: @employee.id).where.not(ended_at: nil).where('started_at < ? AND ended_at > ?', to, from)
        .sum { |s| ([s.ended_at, to].min - [s.started_at, from].max) / 3600.0 }
      [planned, worked].max + @shift.hours_within(from, to) > PayRules.current.overtime_threshold_hours.to_f
    end

    def position_mismatch?
      return false if @shift.position_id.blank?
      return @employee.position_id != @shift.position_id if @rules.open_shift_requires_position? || @employee.position_id.present?

      false
    end

    def minor_checks
      return [] unless @employee.minor?(@shift.starts_at.to_date, rules: @rules)

      list = []
      local_start = @shift.starts_at.in_time_zone(@zone)
      local_end = @shift.ends_at.in_time_zone(@zone)
      earliest = minutes_of(@rules.minor_earliest_start)
      latest = minutes_of(@rules.minor_latest_end)
      start_minute = (local_start.hour * 60) + local_start.min
      end_minute = (local_end.hour * 60) + local_end.min
      if start_minute < earliest || end_minute > latest || local_end.to_date != local_start.to_date
        list << Check.new('block', 'minor_hours', "#{@employee.name} is under #{@rules.minor_age}: shifts must fall between #{@rules.minor_earliest_start} and #{@rules.minor_latest_end}.")
      end
      if @rules.minor_max_daily_hours && @shift.hours > @rules.minor_max_daily_hours.to_f
        list << Check.new('block', 'minor_daily', "Longer than #{plain(@rules.minor_max_daily_hours)} hours, the daily limit for a minor.")
      end
      list
    end

    def minutes_of(clock)
      hours, minutes = clock.to_s.split(':').map(&:to_i)
      (hours * 60) + minutes.to_i
    end

    def short_rest?
      min_rest = @rules.min_rest_between_shifts_hours.to_f.hours
      others = People::ScheduledShift.live.where(employee_id: @employee.id).where.not(id: excluded_ids)
      others.where('ends_at <= ? AND ends_at > ?', @shift.starts_at, @shift.starts_at - min_rest).exists? ||
        others.where('starts_at >= ? AND starts_at < ?', @shift.ends_at, @shift.ends_at + min_rest).exists?
    end

    def unavailable?
      People::EmployeeAvailability.conflicts_for(@employee.id, @shift.starts_at, @shift.ends_at, zone: @zone).any?
    end

    def other_store?
      @shift.location_id.present? && !@employee.works_at?(@shift.location_id)
    end
  end
end
