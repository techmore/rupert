# frozen_string_literal: true

module People
  # Everything payroll needs for one pay period, per employee: hours by kind from approved timesheets,
  # weekly overtime (PayRules) and daily overtime (TimeRules), paid time off from approved requests,
  # tips from the ledger, commission and card bonus from the timesheets, the rate on record and an
  # estimated gross. Also the warnings that should stop a lock. Read-only.
  class PayPeriodSummary
    Row = Struct.new(:employee, :rate, :regular_hours, :overtime_hours, :daily_overtime_hours, :pto_hours, :sick_hours, :personal_hours,
      :unpaid_hours, :holiday_hours, :card_tips_cents, :cash_tips_cents, :commission_cents, :bonus_cents, :adjustments,
      :wages_cents, :estimated_gross_cents, :notes, keyword_init: true) do
      def hourly_rate_cents = rate&.pay_type == 'hourly' ? rate.hourly_rate_cents.to_i : nil
      def salary_cents = rate&.pay_type == 'salary' ? rate.annual_salary_cents.to_i : nil
      def total_hours = regular_hours + overtime_hours + pto_hours + sick_hours + personal_hours + holiday_hours
    end
    Warning = Struct.new(:level, :message, :path, keyword_init: true) do
      def blocking? = level == 'block'
    end

    WORKED_TYPES = %w[regular overtime].freeze

    attr_reader :period, :rules

    def initialize(period, employees: People::Employee.all, rules: PayRules.current)
      @period = period
      @employees = employees.to_a.sort_by(&:name)
      @rules = rules
    end

    def rows
      @rows ||= @employees.filter_map { |employee| row_for(employee) }
    end

    def warnings
      @warnings ||= build_warnings
    end

    def blocking_warnings = warnings.select(&:blocking?)

    def totals
      rows.each_with_object(Hash.new(0)) do |row, sum|
        sum[:hours] += row.total_hours
        sum[:overtime_hours] += row.overtime_hours + row.daily_overtime_hours
        sum[:card_tips_cents] += row.card_tips_cents
        sum[:cash_tips_cents] += row.cash_tips_cents
        sum[:commission_cents] += row.commission_cents + row.bonus_cents
        sum[:gross_cents] += row.estimated_gross_cents
        sum[:employees] += 1
      end
    end

    def to_h
      { 'employees' => rows.size, 'hours' => totals[:hours].to_f.round(2), 'gross_cents' => totals[:gross_cents], 'card_tips_cents' => totals[:card_tips_cents],
        'cash_tips_cents' => totals[:cash_tips_cents], 'warnings' => warnings.map(&:message) }
    end

    private

    def from = period.starts_on
    def to = period.ends_on

    # { employee_id => { worked_on => { work_type => hours } } } from approved, non-demo sheets.
    def approved_hours
      @approved_hours ||= begin
        rows = People::Timesheet.non_demo.approved.where('period_start <= ? AND period_end >= ?', to, from)
                               .joins(:entries).where(timesheet_entries: { worked_on: from..to, tenant_id: Current.tenant_id })
                               .group('timesheets.employee_id', 'timesheet_entries.worked_on', 'timesheet_entries.work_type').sum('timesheet_entries.hours')
        totals = Hash.new { |hash, employee| hash[employee] = Hash.new { |days, day| days[day] = {} } }
        rows.each { |(employee_id, worked_on, work_type), hours| totals[employee_id][worked_on.to_date][work_type] = hours.to_d }
        totals
      end
    end

    def sheets
      @sheets ||= People::Timesheet.non_demo.where('period_start <= ? AND period_end >= ?', to, from).includes(:employee).to_a
    end

    def tips
      @tips ||= TipAllocation.counted.for_period(from, to).group(:employee_id, :tip_method).sum(:amount_cents)
    end

    def leave
      @leave ||= People::LeaveRequest.where(status: 'approved').where('starts_on <= ? AND ends_on >= ?', to, from).to_a.group_by(&:employee_id)
    end

    def shifts
      @shifts ||= ClockShift.where(started_at: from.in_time_zone...(to + 1).in_time_zone).where.not(ended_at: nil).includes(:breaks).to_a.group_by(&:employee_id)
    end

    def adjustments
      @adjustments ||= period.adjustments.includes(:employee).to_a.group_by(&:employee_id)
    end

    def row_for(employee)
      days = approved_hours[employee.id]
      sheet_rows = sheets.select { |s| s.employee_id == employee.id }
      emp_leave = leave.fetch(employee.id, [])
      emp_tips = tips.select { |(id, _m), _v| id == employee.id }
      emp_adjust = adjustments.fetch(employee.id, [])
      return nil if days.empty? && emp_leave.empty? && emp_tips.empty? && emp_adjust.empty? && sheet_rows.empty? && shifts[employee.id].nil?

      regular = days.values.sum { |types| types.fetch('regular', 0).to_d }
      marked_overtime = days.values.sum { |types| types.fetch('overtime', 0).to_d }
      weekly_overtime = weekly_overtime_hours(days)
      overtime = [marked_overtime, weekly_overtime].max
      regular -= [overtime - marked_overtime, regular].min if overtime > marked_overtime
      pto = days.values.sum { |types| types.fetch('pto', 0).to_d }
      holiday = days.values.sum { |types| types.fetch('holiday', 0).to_d }
      sick, personal, unpaid, vacation = leave_hours(emp_leave)
      pto += vacation
      daily_overtime = daily_overtime_hours(shifts.fetch(employee.id, []))
      rate = employee.pay_rate_for(from, to)
      card = emp_tips.sum { |(_id, method), cents| %w[direct pool adjustment].include?(method) ? cents : 0 }
      cash = emp_tips.sum { |(_id, method), cents| method == 'cash' ? cents : 0 }
      commission = sheet_rows.sum(&:commission_cents)
      bonus = sheet_rows.sum(&:card_bonus_cents)
      adjust_hours = emp_adjust.select(&:hours_kind?).sum { |a| a.hours.to_d }
      adjust_cents = emp_adjust.reject(&:hours_kind?).sum { |a| a.kind == 'deduction' ? -a.amount_cents.abs : a.amount_cents }
      wages = wages_cents(rate, regular + adjust_hours, overtime, daily_overtime, pto + sick + personal + holiday)
      notes = []
      notes << 'No pay rate on record' if rate.nil?
      notes << 'Salaried' if rate&.pay_type == 'salary'
      emp_adjust.each { |a| notes << "Adjustment: #{a.kind_label} #{a.label} (#{a.note})" }
      Row.new(employee: employee, rate: rate, regular_hours: regular + adjust_hours, overtime_hours: overtime, daily_overtime_hours: daily_overtime,
        pto_hours: pto, sick_hours: sick, personal_hours: personal, unpaid_hours: unpaid, holiday_hours: holiday,
        card_tips_cents: card, cash_tips_cents: cash, commission_cents: commission, bonus_cents: bonus, adjustments: emp_adjust,
        wages_cents: wages, estimated_gross_cents: wages + commission + bonus + card + cash + adjust_cents, notes: notes)
    end

    def weekly_overtime_hours(days)
      return 0.to_d unless rules.overtime_enabled?

      weeks = Hash.new(0.to_d)
      days.each { |day, types| weeks[rules.week_start(day)] += WORKED_TYPES.sum { |type| types.fetch(type, 0).to_d } }
      weeks.values.sum { |worked| rules.hours_over_threshold(worked) }
    end

    def daily_overtime_hours(employee_shifts)
      employee_shifts.sum do |shift|
        time_rules = TimeRules.for(shift.location_id)
        next 0.to_d unless time_rules.daily_overtime?

        [shift.paid_hours.to_d - time_rules.daily_overtime_threshold_hours, 0].max
      end
    end

    # Hours of each leave type inside the period (a request crossing the period edge is prorated by day).
    def leave_hours(requests)
      sums = Hash.new(0.to_d)
      requests.each do |request|
        days_in = ([request.starts_on, from].max..[request.ends_on, to].min).count
        per_day = (request.hours.presence || request.days * 8).to_d / request.days
        sums[request.leave_type] += per_day * days_in
      end
      [sums['sick'], sums['personal'], sums['unpaid'], sums['vacation']]
    end

    def wages_cents(rate, regular, overtime, daily_overtime, paid_leave)
      return 0 if rate.nil?

      if rate.pay_type == 'hourly'
        cents = rate.hourly_rate_cents.to_i
        base = (regular + overtime + daily_overtime + paid_leave) * cents
        premium = rules.overtime_premium_cents(overtime, cents) + (daily_overtime * cents * (TimeRules.for.daily_overtime_multiplier - 1))
        (base + premium).round.to_i
      else
        People::PayrollCalculator.send(:salary_for, rate, Struct.new(:period_start, :period_end).new(from, to))
      end
    end

    def build_warnings
      list = []
      helpers = Rails.application.routes.url_helpers
      ids = @employees.map(&:id)
      open = sheets.reject(&:approved?)
      open.each do |sheet|
        list << Warning.new(level: 'block', message: "#{sheet.employee&.name}: timesheet #{sheet.period_label} is #{sheet.status == 'rejected' ? 'returned' : sheet.status}, not approved",
          path: helpers.people_timesheet_path(sheet))
      end
      worked = ClockShift.where(employee_id: ids).where(started_at: from.in_time_zone...(to + 1).in_time_zone).distinct.pluck(:employee_id)
      (worked - sheets.map(&:employee_id)).each do |employee_id|
        employee = @employees.find { |e| e.id == employee_id }
        list << Warning.new(level: 'block', message: "#{employee&.name}: clocked hours but no timesheet for this period", path: helpers.people_timesheets_path(from: from.iso8601, to: to.iso8601, status: 'all'))
      end
      ClockCorrection.where(status: 'pending').joins(:clock_shift).where(clock_shifts: { employee_id: ids })
                     .where(clock_shifts: { started_at: from.in_time_zone...(to + 1).in_time_zone }).includes(clock_shift: :employee).each do |correction|
        list << Warning.new(level: 'block', message: "#{correction.clock_shift.employee&.name}: punch fix waiting for review", path: helpers.people_approvals_path(kind: 'correction'))
      end
      ClockShift.stale_open.where(employee_id: ids).where(started_at: from.in_time_zone...(to + 1).in_time_zone).includes(:employee).each do |shift|
        list << Warning.new(level: 'block', message: "#{shift.employee&.name}: never clocked out on #{shift.started_at.strftime('%a %b %-d')}", path: helpers.fix_clock_out_time_clock_path(shift))
      end
      unassigned = TipAllocation.counted.unassigned.for_period(from, to).sum(:amount_cents)
      if unassigned.positive?
        list << Warning.new(level: 'warn', message: "#{ActiveSupport::NumberHelper.number_to_currency(unassigned / 100.0)} of tips not assigned to anyone", path: helpers.respond_to?(:people_tips_path) ? helpers.people_tips_path : nil)
      end
      rows.select { |row| row.rate.nil? }.each do |row|
        list << Warning.new(level: 'warn', message: "#{row.employee.name}: no pay rate on record", path: helpers.people_employee_path(row.employee))
      end
      list
    end
  end
end
