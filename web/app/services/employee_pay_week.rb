# frozen_string_literal: true

# One staff member's pay figures for one pay period (PayRules: weekly or every
# two weeks, from the chosen start day; Thursday-Wednesday weekly until chosen):
# hours, hourly rate, base pay, overtime, commission and tips. A read-only
# estimate for the staff member's page; it does not post to payroll or create payslips.
#
# Commission is 1% of the before-tax, after-discount sales rung up while the
# staff member was clocked in (the same rule as the commission preview). A tip
# is split evenly between the non-admins clocked in when it was left. Admins
# (a linked administrator sign-in) earn no commission and no tips. Hours are the
# recorded punch times, never rounded. Overtime is only estimated when turned on
# in the pay rules: hours over the threshold in each seven-day work week are paid
# at the multiplier. Sales come from imported Shopify/Square/SwipeSimple orders
# and stored C-Trax store-days.
class EmployeePayWeek
  CURRENCY = 'USD'

  attr_reader :employee, :start_date, :end_date, :pay_rate, :hours, :overtime_hours, :sales_cents, :commission_cents, :tip_cents,
    :notes, :rules

  # The first day of the seven-day work week holding `date` (from the pay rules' start day).
  def self.week_start(date)
    PayRules.current.week_start(date)
  end

  # The first day of the pay period holding `date`.
  def self.period_start(date)
    PayRules.current.period_start(date)
  end

  # from/to: a part of a period instead of the whole pay period (the incentive model uses single days and weeks).
  def initialize(employee:, week_of: Date.current, from: nil, to: nil)
    @employee = employee
    @rules = PayRules.current
    @start_date, @end_date = rules.period_range(week_of)
    @start_date = from if from
    @end_date = to || (from ? from + 6 : @end_date)
    @admin = PayRules.admin_employee?(employee)
    @notes = []
    @sales_cents = 0
    @commission_cents = 0
    @tip_cents = 0
    @pay_rate = employee.pay_rate_for(start_date, [end_date, Date.current].min)
    load_shifts
    @hours = own_shifts.sum { |shift| clipped_seconds(shift, window) } / 3600.0
    @overtime_hours = rules.overtime_enabled? ? count_overtime_hours : 0.0
    add_order_sources
    add_ctrax_days
    if own_shifts.any? { |shift| shift.stale_open?(@now) }
      @notes << "A punch has been open more than #{ClockShift::STALE_OPEN_HOURS} hours; it counts only #{ClockShift::STALE_OPEN_HOURS} hours until it is corrected."
    end
    @notes << 'No pay rate is on file, so base pay is unavailable.' unless pay_rate
    @notes << 'An administrator account earns no commission and no share of tips.' if admin?
  end

  def admin? = @admin
  def weeks = ((end_date - start_date).to_i + 1) / 7.0

  def hourly_rate_cents
    pay_rate&.pay_type == 'hourly' ? pay_rate.hourly_rate_cents : nil
  end

  def base_cents
    return nil unless pay_rate
    return ((hours * pay_rate.hourly_rate_cents) + overtime_premium_cents).round if pay_rate.pay_type == 'hourly'

    (pay_rate.annual_salary_cents * [weeks, 1].max.ceil / 52.0).round
  end

  # The extra over straight time for overtime hours (zero unless overtime is turned on).
  def overtime_premium_cents
    return 0 unless overtime_hours.positive? && pay_rate&.pay_type == 'hourly'

    rules.overtime_premium_cents(overtime_hours, pay_rate.hourly_rate_cents)
  end

  def total_cents
    base_cents.to_i + commission_cents + tip_cents
  end

  private

  def window
    start_date.beginning_of_day...(end_date + 1).beginning_of_day
  end

  def load_shifts
    @now = Time.current
    @shifts = ClockShift.where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', window.end, window.begin).to_a
    @groups = @shifts.group_by(&:employee_key)
    @own_keys = @shifts.select { |shift| shift.employee_id == employee.id }.map(&:employee_key).uniq
    @admin_keys = @own_keys.empty? || admin? ? Set.new : PayRules.admin_keys(@shifts)
  end

  def own_shifts
    @shifts.select { |shift| shift.employee_id == employee.id }
  end

  def clipped_seconds(shift, range)
    finish = [shift.counted_end(@now), range.end].min
    [finish - [shift.started_at, range.begin].max, 0].max
  end

  # Hours over the threshold in each seven-day work week of the period.
  def count_overtime_hours
    starts = (start_date..end_date).map { |day| rules.week_start(day) }.uniq
    starts.sum do |week|
      range = week.beginning_of_day...(week + 7).beginning_of_day
      worked = own_shifts.sum { |shift| clipped_seconds(shift, range) } / 3600.0
      rules.hours_over_threshold(worked)
    end
  end

  def add_order_sources
    return if @own_keys.empty? || admin?

    CommissionPreview::SOURCES.each do |source|
      preview = CommissionPreview.cached(start_date: start_date.iso8601, end_date: end_date.iso8601, source: source, currency: CURRENCY)
      row = preview.rows.find { |candidate| candidate[:employee_id] == employee.id }
      next unless row

      @sales_cents += row[:sales_cents]
      @commission_cents += row[:commission_cents]
      @tip_cents += row[:tip_cents]
    end
  rescue CommissionPreview::Error => e
    @notes << "Shopify, Square and SwipeSimple sales were not included: #{e.message}"
  end

  # A C-Trax day's orders, decoded once per CommissionPreview.caching block.
  def ctrax_orders(day)
    store = Thread.current[:commission_preview_cache]
    return Ctrax::Reconciliation.new(day).orders unless store

    store[[:ctrax, day.id, day.updated_at]] ||= Ctrax::Reconciliation.new(day).orders
  end

  def add_ctrax_days
    return if @own_keys.empty? || admin?

    CtraxDay.where(business_date: (start_date - 1)..(end_date + 1), currency: CURRENCY).find_each do |day|
      ctrax_orders(day).each do |order|
        at = Time.iso8601(order['completed_at'].to_s).in_time_zone
        next unless window.cover?(at) && order['total'].is_a?(Integer) && order['tax'].is_a?(Integer) && order['refund_count'].to_i.zero?

        on_shift = @groups.select { |_key, shifts| shifts.any? { |shift| at >= shift.started_at && at < shift.counted_end(@now) } }
        next unless (@own_keys & on_shift.keys).any?

        base = order['total'] - order['tax']
        @sales_cents += base
        @commission_cents += PayRules.commission_cents(base)
        sharers = on_shift.keys - @admin_keys.to_a
        @tip_cents += order['tip'].to_i / sharers.size
      end
    end
  rescue ArgumentError, ActiveRecord::Encryption::Errors::Decryption
    @notes << 'Some C-Trax sales could not be read and were not included.'
  end
end
