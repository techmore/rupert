# frozen_string_literal: true

module People
  # Everything the schedule builder shows for one Monday–Sunday week at one store (or all):
  # the shifts by person and day, the inline warnings per shift, and the labour-cost line.
  # Warnings never block a manager; they are chips on the cell (DESIGN.md).
  class ScheduleWeek
    Warning = Struct.new(:code, :level, :label, keyword_init: true)
    SALES_SOURCES = %w[rupert_pos shopify square swipesimple].freeze
    SALES_WEEKS = 4

    attr_reader :week, :location_id, :shifts, :rules

    def initialize(week, location_id: nil)
      @week = week
      @location_id = location_id.presence
      @location = @location_id && Location.find_by(id: @location_id)
      @rules = TimeRules.for(@location)
      @zone = BusinessClock.zone(tenant: Current.tenant, location: @location)
      @shifts = People::ScheduledShift.between(week, week + 6).live.for_location(@location_id).chronological
        .includes(:employee, :location, :position).to_a
    end

    def days = (week..(week + 6)).to_a

    def employees
      ids = shifts.filter_map(&:employee_id)
      People::Employee.active.ordered.includes(:pay_rates, :position).to_a.tap do |list|
        missing = ids - list.map(&:id)
        list.concat(People::Employee.where(id: missing).to_a) if missing.any?
      end
    end

    def open_shifts = shifts.select(&:open?)
    def shifts_for(employee_id, day) = shifts.select { |s| s.employee_id == employee_id && s.starts_at.in_time_zone(@zone).to_date == day }
    def open_shifts_for(day) = open_shifts.select { |s| s.starts_at.in_time_zone(@zone).to_date == day }
    def published? = shifts.any? && shifts.all?(&:published?)
    def draft_count = shifts.count { |s| !s.published? }

    # Warnings per shift id (computed once for the week).
    def warnings
      @warnings ||= shifts.index_with { |shift| warnings_for(shift) }
    end

    def warnings_for(shift)
      list = []
      return list if shift.employee.nil?

      employee = shift.employee
      day = shift.starts_at.to_date
      leave = leave_by_employee.fetch(employee.id, []).find { |l| l.starts_on <= shift.ends_at.to_date && l.ends_on >= day }
      list << Warning.new(code: 'time_off', level: leave.approved? ? 'rose' : 'clay', label: leave.approved? ? 'Time off' : 'Time off requested') if leave
      list << Warning.new(code: 'availability', level: 'clay', label: 'Unavailable') if availability_conflict?(shift)
      total = weekly_hours[employee.id]
      list << Warning.new(code: 'over_hours', level: 'clay', label: "#{total.round(1)} h this week") if total && total > People::ScheduledShift::PLANNED_HOURS_LIMIT
      list << Warning.new(code: 'short_rest', level: 'clay', label: 'Short rest') if short_rest?(shift)
      list.concat(minor_warnings(shift))
      list << Warning.new(code: 'blackout', level: 'olive', label: 'Blackout') if blackouts.any? { |b| b.starts_on <= day && b.ends_on >= day }
      list
    end

    # Planned paid hours × hourly rate per day and for the week, against the average sales for the
    # same weekday over the last SALES_WEEKS weeks.
    def labor
      @labor ||= begin
        by_day = days.index_with { |day| { cost_cents: 0, hours: 0.0, salaried: 0 } }
        shifts.each do |shift|
          next if shift.employee.nil?

          day = shift.starts_at.in_time_zone(@zone).to_date
          row = by_day[day] or next
          rate = shift.employee.current_pay_rate
          row[:hours] += shift.paid_hours
          if rate&.pay_type == 'hourly' && rate.hourly_rate_cents.to_i.positive?
            row[:cost_cents] += (shift.paid_hours * rate.hourly_rate_cents).round
          elsif rate&.pay_type == 'salary'
            row[:salaried] += 1
          end
        end
        by_day.each { |day, row| row[:sales_cents] = average_sales_cents(day) }
        by_day
      end
    end

    def labor_total
      labor.values.each_with_object({ cost_cents: 0, hours: 0.0, sales_cents: 0, salaried: 0 }) do |row, sum|
        sum[:cost_cents] += row[:cost_cents]
        sum[:hours] += row[:hours]
        sum[:sales_cents] += row[:sales_cents]
        sum[:salaried] += row[:salaried]
      end
    end

    def self.percent(cost_cents, sales_cents)
      return nil if sales_cents.to_i <= 0

      (cost_cents.to_f / sales_cents * 100).round(1)
    end

    private

    def leave_by_employee
      @leave_by_employee ||= People::LeaveRequest.where(status: %w[requested approved], employee_id: shifts.filter_map(&:employee_id).uniq)
        .where('starts_on <= ? AND ends_on >= ?', week + 6, week).group_by(&:employee_id)
    end

    def blackouts
      @blackouts ||= People::BlackoutDate.overlapping(week, week + 6).where(location_id: [@location_id, nil].uniq).to_a
    end

    def availabilities
      @availabilities ||= People::EmployeeAvailability.where(kind: 'unavailable', employee_id: shifts.filter_map(&:employee_id).uniq).to_a.group_by(&:employee_id)
    end

    def availability_conflict?(shift)
      blocks = availabilities[shift.employee_id] or return false
      local_start = shift.starts_at.in_time_zone(@zone)
      local_end = shift.ends_at.in_time_zone(@zone)
      blocks.any? do |block|
        day = local_start.to_date
        day += 1 while day <= local_end.to_date && day.wday != block.weekday
        next false if day > local_end.to_date

        block_start = @zone.local(day.year, day.month, day.day) + block.start_minute.minutes
        block_end = @zone.local(day.year, day.month, day.day) + block.end_minute.minutes
        block_start < shift.ends_at && block_end > shift.starts_at
      end
    end

    # Hours per employee in the pay week(s) the grid touches; the larger of the two weeks.
    def weekly_hours
      @weekly_hours ||= begin
        starts = [EmployeePayWeek.week_start(week), EmployeePayWeek.week_start(week + 6)].uniq
        nearby = People::ScheduledShift.live.between(starts.first, starts.last + 6).where.not(employee_id: nil).to_a
        nearby.group_by(&:employee_id).transform_values do |list|
          starts.map { |start| list.sum { |s| s.hours_within(start.in_time_zone, (start + 7).in_time_zone) } }.max
        end
      end
    end

    def short_rest?(shift)
      min_rest = rules.min_rest_between_shifts_hours.to_f.hours
      neighbours = People::ScheduledShift.live.where(employee_id: shift.employee_id).where.not(id: shift.id)
      neighbours.where('ends_at <= ? AND ends_at > ?', shift.starts_at, shift.starts_at - min_rest).exists?
    end

    def minor_warnings(shift)
      return [] unless shift.employee.minor?(shift.starts_at.to_date, rules: rules)

      list = []
      local_start = shift.starts_at.in_time_zone(@zone)
      local_end = shift.ends_at.in_time_zone(@zone)
      earliest = rules.minor_earliest_start.split(':').map(&:to_i)
      latest = rules.minor_latest_end.split(':').map(&:to_i)
      outside = (local_start.hour * 60) + local_start.min < (earliest[0] * 60) + earliest[1].to_i ||
        (local_end.hour * 60) + local_end.min > (latest[0] * 60) + latest[1].to_i || local_end.to_date != local_start.to_date
      list << Warning.new(code: 'minor_hours', level: 'rose', label: "Minor · outside #{rules.minor_earliest_start}–#{rules.minor_latest_end}") if outside
      list << Warning.new(code: 'minor_daily', level: 'rose', label: 'Minor · over daily limit') if rules.minor_max_daily_hours && shift.hours > rules.minor_max_daily_hours.to_f
      list
    end

    def average_sales_cents(day)
      sales_by_day.fetch(day, 0)
    end

    # One query for the whole window: net sales per calendar day (store zone) for the SALES_WEEKS weeks
    # before the grid, then the same-weekday average for each day shown.
    def sales_by_day
      @sales_by_day ||= begin
        from = (week - (7 * SALES_WEEKS)).in_time_zone(@zone).beginning_of_day
        to = (week - 1).in_time_zone(@zone).end_of_day
        scope = Core::Order.where(source: SALES_SOURCES).where(occurred_at: from..to)
        scope = scope.where(location_id: @location_id) if @location_id && Core::Order.where(location_id: @location_id).exists?
        totals = Hash.new(0)
        scope.pluck(:occurred_at, Arel.sql('gross_cents - tax_cents - tip_cents')).each do |at, net|
          totals[at.in_time_zone(@zone).to_date] += net.to_i
        end
        days.index_with { |day| (1..SALES_WEEKS).sum { |n| totals[day - (7 * n)] } / SALES_WEEKS }
      end
    end
  end
end
