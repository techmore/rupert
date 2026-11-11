# frozen_string_literal: true

# The signed-in worker's own pay for one pay period: hours, estimated gross, tips (card from the
# terminal and gateway, cash they declared), bonuses, next payday and finalized payslips. Every
# record starts from the worker link; nothing is selected by an identifier from the browser.
class EmployeePayController < AuthenticatedController
  layout 'employee'
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :require_worker
  before_action -> { require_time_feature(:pay_view) }, only: :show
  before_action -> { require_time_feature(:pay_view, :tips_view) }, only: :declare_tips

  # GET /employee/pay?period=YYYY-MM-DD (any date in the pay period; today by default)
  def show
    date = begin
      params[:period].present? ? Date.iso8601(params[:period].to_s) : Date.current
    rescue Date::Error
      Date.current
    end
    @rules = PayRules.current
    @time_rules = TimeRules.for(@worker.location_ids.first)
    @pay = EmployeePayWeek.new(employee: @worker, week_of: date)
    @period = PayPeriod.find_by(starts_on: @pay.start_date) || PayPeriod.new(starts_on: @pay.start_date, ends_on: @pay.end_date, status: 'open')
    @final = @period.locked?
    @payday = @pay.end_date + @time_rules.payday_days_after_period_end
    @shifts = ClockShift.where(employee_id: @worker.id).where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', (@pay.end_date + 1).beginning_of_day, @pay.start_date.beginning_of_day)
      .includes(:breaks).order(:started_at).to_a
    @allocations = @pay.tip_allocations
    @days = (@pay.start_date..@pay.end_date).map { |day| day_row(day) }
    @bonus_cents = bonus_cents
    @payslips = @worker.payslips.joins(:pay_run).where(pay_runs: { tenant_id: Current.tenant_id, status: %w[finalized paid] })
      .where('pay_runs.period_end >= ? AND pay_runs.period_start <= ?', @pay.start_date, @pay.end_date).includes(:pay_run).order('pay_runs.period_start DESC')
    @declarable_shifts = @shifts.select(&:closed?).last(7).reverse
    @tips_on = TimeRules.feature?(:tips_view)
  end

  # POST /employee/tips/declare — cash tips for one of my shifts (or a day).
  def declare_tips
    values = params.require(:cash_tips).permit(:amount, :shift_id, :on)
    cents = (BigDecimal(values[:amount].to_s.delete(',').presence || '0') * 100).to_i
    Tips::Declare.call(worker: @worker, amount_cents: cents, shift: values[:shift_id].presence, on: values[:on].presence)
    redirect_to employee_pay_path(period: params[:period].presence, anchor: 'cash-tips'), notice: t('time.pay.cash_saved')
  rescue Tips::Declare::Error, ArgumentError => e
    redirect_to employee_pay_path(period: params[:period].presence, anchor: 'cash-tips'), alert: e.message
  end

  private

  def require_worker
    @worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
    return skip_authorization if @worker

    redirect_to employee_app_path, alert: 'Ask an administrator to link your staff record before using your personal workspace.'
  end

  def day_row(day)
    from = day.beginning_of_day
    to = (day + 1).beginning_of_day
    now = Time.current
    seconds = @shifts.sum do |shift|
      finish = [shift.counted_end(now), to].min
      start = [shift.started_at, from].max
      finish > start ? [(finish - start) - (shift.closed? && shift.started_at >= from && shift.ended_at <= to ? shift.unpaid_break_seconds : 0), 0].max : 0
    end
    rows = @allocations.select { |a| a.business_date == day }
    { date: day, hours: seconds / 3600.0, card_cents: rows.select(&:card?).sum(&:amount_cents),
      cash_cents: rows.select { |a| a.tip_method == 'cash' }.sum(&:amount_cents), estimated: rows.any? { |a| !a.final? } }
  end

  # Commission (1%) plus the card-redemption bonus from this period's timesheets.
  def bonus_cents
    sheets = @worker.timesheets.where('period_end >= ? AND period_start <= ?', @pay.start_date, @pay.end_date)
    sheets.sum { |sheet| TimesheetCompensation.calculate(sales_cents: 0, card_redemptions: sheet.card_redemptions.to_i)[:total_cents] }
  end
end
