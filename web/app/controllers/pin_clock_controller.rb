# frozen_string_literal: true

# The PIN clock: the pad on the POS strip and the full-screen kiosk at /clock. A punch is accepted
# when the browser is a registered store device (ClockDevice cookie) or the signed-in person is the
# worker the PIN names; the service refuses everything else. No sign-in is needed to reach the kiosk.
class PinClockController < ApplicationController
  layout 'pos'
  skip_before_action :require_login
  skip_before_action :enforce_workspace_location, raise: false
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :load_device
  before_action :require_store

  rescue_from TimeClockService::Error, ActiveRecord::RecordInvalid, with: :punch_error
  rescue_from ActiveRecord::StatementInvalid, with: :database_error

  # Full-screen pad for a counter tablet.
  def kiosk
    @trusted = @device.present?
    @can_register = Current.user&.can?('hr.write')
    @locations = Location.for_shifts.order(:name) if @can_register
    @own_worker = Current.user && TimeClockService.worker_for(Current.user)
  end

  # One punch. JSON from the pad (fetch), HTML as a no-script fallback. Wrong PINs are counted per
  # device or session: after the store's limit the pad refuses for the lockout window, whoever the
  # digits were meant for (a worker's own PIN also locks itself, People::Employee#verify_pin).
  def punch
    rules = TimeRules.for(params[:location_id].presence || @device&.location_id)
    raise TimeClockService::Error, t('time.clock.locked', minutes: rules.pin_lockout_minutes) if pad_locked?(rules)

    result = TimeClockService.pin_punch(
      pin: params[:pin], action: params[:clock_action], device: @device, user: Current.user,
      location_id: params[:location_id].presence, register_name: params[:register_name].presence,
      request_token: params[:request_token].presence, at: params[:punched_at].presence,
      break_kind: params[:break_kind].presence, proposed_ended_at: params[:proposed_ended_at].presence, reason: params[:reason].presence
    )
    respond_to do |format|
      format.json { render json: payload(result) }
      format.html { redirect_to clock_kiosk_path, notice: payload(result)[:message] }
    end
  end

  # First use: a worker without a PIN chooses one. Identified by employee number, or by their own
  # signed-in session; on a trusted device anyone's number works (the number is on their badge).
  def setup
    worker = worker_for_setup
    raise TimeClockService::Error, t('time.clock.setup.not_found') unless worker
    raise TimeClockService::Error, t('time.clock.setup.already_set') if worker.pin_set? && !(Current.user && worker.user_id == Current.user.id)

    TimeClockService.set_clock_pin!(worker, params[:pin], confirmation: params[:pin_confirmation])
    ActivityLogger.log('clock_pin.set', subject: worker, details: { by: Current.user&.id, device: @device&.id }.to_json) if defined?(ActivityLogger)
    respond_to do |format|
      format.json { render json: { ok: true, first_name: worker.first_name, message: t('time.clock.setup.done', name: worker.first_name) } }
      format.html { redirect_to clock_kiosk_path, notice: t('time.clock.setup.done', name: worker.first_name) }
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to clock_kiosk_path, alert: e.message }
    end
  end

  # Names for the first-use picker (trusted device or signed-in manager only; employees see just themselves).
  def workers
    scope = People::Employee.active.where(pin_digest: nil).ordered
    scope = scope.where(user_id: Current.user.id) unless @device || Current.user&.can?('hr.read')
    render json: { data: scope.map { |w| { id: w.id, name: w.name, number: w.employee_number } } }
  end

  private

  # A registered device carries its store with it, so the kiosk works on any host name (and before
  # anyone signs in): the device's workspace becomes the request's workspace when none is known.
  def load_device
    secret = cookies.signed[ClockDevice::COOKIE]
    if Current.tenant.nil? && secret.present?
      device = ClockDevice.unscoped.active.find_by(token_digest: ClockDevice.digest(secret))
      Current.tenant = Tenant.find_by(id: device.tenant_id) if device && Current.user.nil?
    end
    @device = ClockDevice.authenticate(secret)
  end

  # Punches need a store. The kiosk page itself still renders without one (an unregistered browser,
  # nobody signed in) so it can say "sign in or register this device".
  def require_store
    return if Current.tenant&.status == 'active'
    return if action_name == 'kiosk'

    respond_to do |format|
      format.json { render json: { ok: false, error: t('time.clock.untrusted') }, status: :unauthorized }
      format.html { redirect_to login_path }
    end
  end

  def worker_for_setup
    if params[:employee_id].present? && (@device || Current.user&.can?('hr.read'))
      People::Employee.active.find_by(id: params[:employee_id])
    elsif params[:employee_number].present? && (@device || Current.user)
      worker = People::Employee.active.find_by(employee_number: params[:employee_number].to_s.strip)
      worker if worker && (@device || Current.user.can?('hr.read') || worker.user_id == Current.user.id)
    elsif Current.user
      TimeClockService.worker_for(Current.user)
    end
  end

  def payload(result)
    shift = result.shift
    open_break = shift&.open_break
    zone = BusinessClock.zone(tenant: Current.tenant, location: shift&.location)
    at = result.at.in_time_zone(zone)
    {
      ok: true, event: result.event, state: result.state, first_name: result.worker.first_name,
      own: Current.user.present? && result.worker.user_id == Current.user.id,
      time_label: at.strftime('%-l:%M %p'), message: message_for(result, at),
      shift: shift && { id: shift.id, started_at: shift.started_at.iso8601, hours: shift.hours.round(2), on_break: shift.on_break?,
                        break_kind: open_break&.kind, break_minutes: open_break&.minutes,
                        stale: result.stale.present?, started_label: shift.started_at.in_time_zone(zone).strftime('%a %b %-d · %-l:%M %p') },
      fix_options: result.event == 'needs_fix' ? fix_options(result.stale, zone) : nil
    }
  end

  def message_for(result, at)
    name = result.worker.first_name
    case result.event
    when 'clocked_in', 'fixed_and_clocked_in' then t('time.clock.confirm.clocked_in', time: at.strftime('%-l:%M %p'))
    when 'clocked_out' then t('time.clock.confirm.clocked_out', time: at.strftime('%-l:%M %p'), hours: format('%.1f', result.shift.paid_hours))
    when 'break_started' then t('time.clock.confirm.break_started', time: at.strftime('%-l:%M %p'))
    when 'meal_started' then t('time.clock.confirm.meal_started', time: at.strftime('%-l:%M %p'))
    when 'break_ended' then t('time.clock.confirm.break_ended', time: at.strftime('%-l:%M %p'))
    when 'needs_fix' then t('time.clock.fix.title', day: result.stale.started_at.in_time_zone.strftime('%a'))
    when 'already_in' then t('time.clock.state.already_in', name: name)
    else name
    end
  end

  # Choices for the real clock-out of a forgotten punch: the planned end, a usual 8 hours, or custom.
  def fix_options(stale, zone)
    options = []
    planned = stale.scheduled_shift || People::ScheduledShift.live.where(employee_id: stale.employee_id).where(starts_at: stale.started_at.all_day).order(:starts_at).first
    if planned && planned.ends_at > stale.started_at && planned.ends_at <= Time.current
      options << { label: t('time.clock.fix.planned_end', time: planned.ends_at.in_time_zone(zone).strftime('%-l:%M %p')), at: planned.ends_at.iso8601 }
    end
    eight = stale.started_at + 8.hours
    options << { label: t('time.clock.fix.eight_hours', time: eight.in_time_zone(zone).strftime('%-l:%M %p')), at: eight.iso8601 } if eight <= Time.current
    options
  end

  def pad_key = "pin_pad:#{Current.tenant_id}:#{@device&.id || session.id&.to_s || request.remote_ip}"

  def pad_locked?(rules)
    Rails.cache.read(pad_key).to_i >= rules.pin_lockout_attempts
  end

  def count_wrong_pin!
    rules = TimeRules.for(params[:location_id].presence || @device&.location_id)
    count = Rails.cache.increment(pad_key, 1, expires_in: rules.pin_lockout_minutes.minutes) || 1
    Rails.cache.write(pad_key, count, expires_in: rules.pin_lockout_minutes.minutes) if count == 1
  end

  def punch_error(error)
    message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
    count_wrong_pin! if action_name == 'punch' && message == t('time.clock.wrong_pin')
    respond_to do |format|
      format.json { render json: { ok: false, error: message }, status: :unprocessable_entity }
      format.html { redirect_to clock_kiosk_path, alert: message }
    end
  end

  def database_error(error)
    raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause&.class&.name)

    respond_to do |format|
      format.json { render json: { ok: false, error: t('time.clock.busy'), retry: true }, status: :service_unavailable }
      format.html { redirect_to clock_kiosk_path, alert: t('time.clock.busy') }
    end
  end
end
