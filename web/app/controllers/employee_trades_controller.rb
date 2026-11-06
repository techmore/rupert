# frozen_string_literal: true

# A worker's own give-aways, swaps and pick-ups. Every record starts from the signed-in worker.
class EmployeeTradesController < AuthenticatedController
  layout 'employee'
  before_action { response.headers['Cache-Control'] = 'no-store' }
  before_action :require_worker
  rescue_from People::ShiftTradeWorkflow::Error, with: :refused

  def index
    mine = People::ShiftTrade.where('from_employee_id = :id OR to_employee_id = :id', id: @worker.id)
    @mine = mine.includes(:scheduled_shift, :counter_shift, :from_employee, :to_employee).recent.limit(100).to_a
    # Offers from colleagues I could take: give-aways at my stores, and swaps addressed to me.
    offers = People::ShiftTrade.where(status: 'open').where.not(from_employee_id: @worker.id)
      .where('kind = ? OR (kind = ? AND to_employee_id = ?)', 'give', 'swap', @worker.id)
      .includes(:scheduled_shift, :counter_shift, :from_employee).recent.to_a
    @offers = offers.select { |t| t.scheduled_shift.starts_at > Time.current && @worker.works_at?(t.scheduled_shift.location_id) }
  end

  # POST /employee/trades  kind=give|swap|pickup shift_id=… [counter_shift_id] [note]
  def create
    shift = People::ScheduledShift.live.published.find(params[:shift_id])
    counter = params[:counter_shift_id].present? ? People::ScheduledShift.live.published.find(params[:counter_shift_id]) : nil
    trade = People::ShiftTradeWorkflow.offer(shift, kind: params[:kind].to_s, by: Current.user, counter_shift: counter, note: params[:note].to_s.strip.presence)
    redirect_to employee_trades_path, notice: t("time.schedule.trades.sent.#{trade.kind}", default: 'Sent.')
  end

  def accept
    trade = People::ShiftTrade.find(params[:id])
    People::ShiftTradeWorkflow.accept(trade, by: Current.user)
    redirect_to employee_trades_path, notice: trade.reload.status == 'approved' ? t('time.schedule.trades.accepted_done') : t('time.schedule.trades.accepted_waiting')
  end

  def cancel
    trade = People::ShiftTrade.find(params[:id])
    People::ShiftTradeWorkflow.cancel(trade, by: Current.user)
    redirect_to employee_trades_path, notice: t('time.schedule.trades.cancelled')
  end

  private

  def require_worker
    @worker = TimeClockService.worker_for(Current.user)
    return skip_authorization if @worker

    redirect_to employee_app_path, alert: 'Ask an administrator to link your staff record before trading shifts.'
  end

  def refused(error)
    redirect_to employee_trades_path, alert: error.message
  end
end
