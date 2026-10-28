# frozen_string_literal: true

module People
  # Turns approved timesheets (and current pay rates) into payslips for a pay
  # run. Hourly employees are paid from their approved hours; salaried staff are
  # paid a prorated slice of their annual salary.
  #
  # Overtime follows the workspace PayRules (#423): off by default, so every
  # hour is paid at the hourly rate. When an owner turns it on, worked hours
  # (regular and overtime entries; not PTO or holiday) over the threshold in
  # each seven-day work week are paid at the multiplier. Only days inside the
  # pay run count toward a week that straddles the pay run's start or end.
  #
  # Deductions are a PLACEHOLDER: a flat 15% estimate on any payslip without a
  # hand-entered amount. It is not a tax or withholding calculation; real
  # deductions wait for qualified payroll review (#424, #425).
  class PayrollCalculator
    TAX_ESTIMATE = BigDecimal('0.15')
    WORKED_TYPES = %w[regular overtime].freeze

    # Rebuilds the payslips for a draft pay run. Returns the payslips.
    def self.generate!(pay_run)
      raise ActiveRecord::RecordNotFound unless pay_run.tenant_id == Current.tenant_id

      pay_run.class.transaction do
        Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
        pay_run.reload
        raise ArgumentError, 'Only draft pay runs can be regenerated' unless pay_run.draft?

        pay_run.payslips.destroy_all

        rules = PayRules.load(pay_run.tenant_id)
        pay_run.employees_without_rate = []
        approved_hours(pay_run).each do |employee_id, days|
          hours = days.values.sum { |types| types.values.sum }
          employee = People::Employee.find(employee_id)
          rate = employee.pay_rate_for(pay_run.period_start, pay_run.period_end)
          # Approved hours with no rate are never dropped silently: the pay run page lists them.
          next pay_run.employees_without_rate << employee if rate.nil?

          pay_run.payslips.create!(
            employee: employee,
            pay_rate: rate,
            hours: hours,
            gross_cents: gross_for(rate, hours, overtime_hours(days, rules), pay_run, rules: rules),
            deductions_cents: 0,
            net_cents: 0
          )
        end
        apply_default_deductions(pay_run)
        pay_run.payslips
      end
    end

    # Applies the placeholder 15% estimate to every payslip that has none.
    def self.apply_default_deductions(pay_run)
      pay_run.payslips.each do |slip|
        next if slip.deductions_cents.positive?

        deductions = (slip.gross_cents * TAX_ESTIMATE).round
        slip.update!(
          deductions_cents: deductions,
          net_cents: slip.gross_cents - deductions
        )
      end
    end

    # Hourly: every hour at the rate, plus the premium (multiplier − 1) on
    # overtime hours. Overtime hours are zero unless PayRules turns it on.
    def self.gross_for(rate, hours, overtime, pay_run, rules: nil)
      if rate.pay_type == 'hourly'
        premium = (rules || PayRules.current).overtime_premium_cents(overtime.to_d, rate.hourly_rate_cents)
        ((hours.to_d * rate.hourly_rate_cents) + premium).round.to_i
      else
        salary_for(rate, pay_run)
      end
    end

    # Weekly and biweekly salaries use 52/26 installments, prorated by
    # inclusive scheduled days. Monthly salaries use calendar-month shares.
    def self.salary_for(rate, pay_run)
      annual = BigDecimal(rate.annual_salary_cents.to_s)
      first = pay_run.period_start
      last = pay_run.period_end
      return 0 if last < first

      if rate.pay_frequency == 'monthly'
        amount = BigDecimal('0')
        while first <= last
          through = [first.end_of_month, last].min
          amount += annual / 12 * ((through - first).to_i + 1) / first.end_of_month.day
          first = through + 1
        end
        amount.round.to_i
      else
        days = (last - first).to_i + 1
        (annual * days / 364).round.to_i
      end
    end

    # Hours over the PayRules threshold in each seven-day work week, counting
    # worked entries only. Zero when overtime is off (the default).
    def self.overtime_hours(days, rules)
      return 0 unless rules.overtime_enabled?

      weeks = Hash.new(0.to_d)
      days.each do |day, types|
        weeks[rules.week_start(day)] += WORKED_TYPES.sum { |type| types.fetch(type, 0).to_d }
      end
      weeks.values.sum { |worked| rules.hours_over_threshold(worked) }
    end

    # Approved hours per employee inside the pay window:
    # { employee_id => { worked_on => { work_type => hours } } }.
    def self.approved_hours(pay_run)
      rows = People::Timesheet.non_demo.approved
                              .where('period_start <= ? AND period_end >= ?', pay_run.period_end, pay_run.period_start)
                              .joins(:entries)
                              .where(timesheet_entries: { worked_on: pay_run.period_start..pay_run.period_end, tenant_id: Current.tenant_id })
                              .group('timesheets.employee_id', 'timesheet_entries.worked_on', 'timesheet_entries.work_type')
                              .sum('timesheet_entries.hours')

      totals = Hash.new { |hash, employee| hash[employee] = Hash.new { |days, day| days[day] = {} } }
      rows.each do |(employee_id, worked_on, work_type), hours|
        totals[employee_id][worked_on.to_date][work_type] = hours.to_d
      end
      totals
    end

    private_class_method :gross_for, :salary_for, :approved_hours, :overtime_hours
  end
end
