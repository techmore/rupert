# frozen_string_literal: true

class TimeClockController < AuthenticatedController
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :active_context
  before_action :authorize_reviewer, only: %i[approve_correction reject_correction]
  # Self-service punches: gated by active_context and scoped to Current.user's own shifts (TimeClockService
  # checks the shift owner). Correction reviews are gated by authorize_reviewer (ClockCorrection.reviewer?);
  # commissions still authorize against the module policy.
  skip_after_action :verify_authorized, only: %i[index clock_in clock_out start_break end_break request_correction fix_clock_out approve_correction reject_correction]
  rescue_from TimeClockService::Error, ActiveRecord::RecordInvalid, with: :clock_error
  rescue_from ActiveRecord::StatementInvalid, with: :database_error

  def index
    @worker = TimeClockService.worker_for(Current.user)
    @open_shift = ClockShift.open.find_by(user_id: Current.user.id)
    @pagy, @shifts = pagy(:offset, ClockShift.where(user_id: Current.user.id).recent.includes(:corrections), limit: 30)
    @open_clock_outs = OpenClockOuts.new
    @open_items = @open_clock_outs.items(employee_ids: OpenClockOuts.manager?(Current.user) ? nil : [@worker&.id].compact)
    if ClockCorrection.reviewer?(Current.user)
      @pending_corrections = ClockCorrection.where(status: 'pending').includes(:clock_shift).order(:created_at).limit(100)
    end
  end

  # Fix clock-out: the correction form for a forgotten clock-out, pre-filled. The worker's own shift, or
  # anyone's for a manager (gate: TimeClockService.correctable_shift). Nothing changes until review.
  def fix_clock_out
    @shift = TimeClockService.correctable_shift(Current.user, params[:id])
    return redirect_to(time_clock_path, notice: 'That shift is already clocked out.') if @shift.ended_at

    @pending = @shift.corrections.where(status: 'pending').order(:created_at).last
    planned = People::ScheduledShift.where(employee_id: @shift.employee_id).where(starts_at: @shift.started_at.all_day).order(:starts_at).first if @shift.employee_id
    @suggested_end = planned&.ends_at if planned&.ends_at && planned.ends_at > @shift.started_at && planned.ends_at <= Time.current
  end

  def clock_in
    shift = TimeClockService.clock_in(user: Current.user, request_token: params[:request_token].to_s, source: params[:source].presence || 'web',
      location_id: params[:location_id].presence)
    redirect_to return_path, notice: t('time.clock.confirm.clocked_in', time: shift.started_at.in_time_zone.strftime('%-l:%M %p'))
  end

  def clock_out
    shift = TimeClockService.clock_out(user: Current.user, shift_id: params[:shift_id])
    redirect_to return_path, notice: t('time.clock.confirm.clocked_out', time: shift.ended_at.in_time_zone.strftime('%-l:%M %p'), hours: format('%.1f', shift.paid_hours))
  end

  # Break / Meal on the signed-in person's own open shift.
  def start_break
    shift = ClockShift.open.find_by!(user_id: Current.user.id)
    TimeClockService.start_break(shift: shift, kind: params[:kind])
    key = params[:kind].to_s == 'meal' ? 'meal_started' : 'break_started'
    redirect_to return_path, notice: t("time.clock.confirm.#{key}", time: Time.current.in_time_zone.strftime('%-l:%M %p'))
  end

  def end_break
    shift = ClockShift.open.find_by!(user_id: Current.user.id)
    TimeClockService.end_break(shift: shift)
    redirect_to return_path, notice: t('time.clock.confirm.break_ended', time: Time.current.in_time_zone.strftime('%-l:%M %p'))
  end

  def request_correction
    attrs = params.require(:clock_correction).permit(:proposed_started_at, :proposed_ended_at, :reason, proposed_breaks: %i[kind started_at ended_at _destroy]).to_h.symbolize_keys
    attrs[:proposed_breaks] = attrs[:proposed_breaks].values if attrs[:proposed_breaks].is_a?(Hash)
    correction = TimeClockService.request_correction(user: Current.user, shift_id: params[:id], attributes: attrs)
    if correction.clock_shift.user_id == Current.user.id
      redirect_to time_clock_path, notice: 'Correction requested. Your shift stays unchanged until review.'
    else
      redirect_to time_clock_path, notice: "Correction requested for #{correction.clock_shift.employee_name}. Another reviewer approves it; the shift stays unchanged until then."
    end
  end

  def approve_correction
    TimeClockService.review(correction: ClockCorrection.find(params[:id]), reviewer: Current.user, approve: true)
    redirect_to review_return_path, notice: 'Correction approved. Re-import the clock shifts on the draft timesheet to use the new times.'
  end

  def reject_correction
    TimeClockService.review(correction: ClockCorrection.find(params[:id]), reviewer: Current.user, approve: false)
    redirect_to review_return_path, notice: 'Correction rejected; shift times are unchanged.'
  end

  def commissions
    authorize(:module, :payroll_read?)
    @start_date = params[:start_date].presence || 6.days.ago.to_date.iso8601
    @end_date = params[:end_date].presence || Date.current.iso8601
    @source = params[:source].presence || 'shopify'
    @currency = params[:currency].presence || 'USD'
    @preview = CommissionPreview.new(start_date: @start_date, end_date: @end_date, source: @source, currency: @currency)
  rescue CommissionPreview::Error => e
    @preview_error = e.message
    render :commissions, status: :unprocessable_entity
  end

  private

  # Punches from the staff home go back there; everything else returns to the time clock.
  def return_path
    params[:return_to].to_s == 'home' ? employee_app_path : time_clock_path
  end

  def active_context
    return if Current.user.active? && Current.tenant&.status == 'active'

    redirect_to root_path, alert: 'An active sign-in account and store are required.'
  end

  # Correction reviews started from a timesheet go back to it; anything else returns to the time clock.
  def review_return_path
    path = params[:return_to].to_s
    path.match?(%r{\A/people/timesheets/\d+\z}) ? path : time_clock_path
  end

  # Timesheet reviewers and payroll writers (ClockCorrection.reviewer?); the service repeats the check.
  def authorize_reviewer
    raise Pundit::NotAuthorizedError unless ClockCorrection.reviewer?(Current.user)
  end

  def clock_error(error)
    message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
    redirect_to time_clock_path, alert: message
  end

  def database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    redirect_to time_clock_path, alert: 'The time clock is busy. Retry your request; it is safe to retry the same clock-in/out.'
  end
end
