# frozen_string_literal: true

class EmployeeAppController < ApplicationController
  layout 'employee'
  before_action -> { response.headers['Cache-Control'] = 'no-store' }, only: %i[show privacy devices revoke week]
  skip_before_action :require_login, only: %i[show privacy manifest service_worker]
  # This public script contains no session or employee data. Rails otherwise
  # rejects non-XHR JavaScript responses, including service worker registration.
  skip_after_action :verify_same_origin_request, only: :service_worker
  before_action -> { require_login if Current.user }, only: :show

  def privacy
    @preview = params[:preview] == '1' && Current.user&.can_manage_accounts?
  end

  def show
    response.headers['Cache-Control'] = 'no-store'
    return unless Current.user

    @preview = params[:preview] == '1' && Current.user.can_manage_accounts?
    if @preview
      @summary = EmployeeWorkSummary.preview
      @worker = @summary.employee
    elsif (@worker = TimeClockService.worker_for(Current.user, include_on_leave: true))
      # The pay week (PayRules), so home, the timesheet and pay all count the same days.
      first, last = PayRules.current.period_range(Date.current)
      @summary = EmployeeWorkSummary.new(employee: @worker, from: first, to: last)
      @open_shift = ClockShift.open.find_by(employee_id: @worker.id, user_id: Current.user.id)
      @timesheet = @worker.timesheets.where('period_start <= ? AND period_end >= ?', Date.current, Date.current).first
      @next_shift = @worker.scheduled_shifts.where('ends_at > ?', Time.current).chronological.first
      @next_leave = @worker.leave_requests.where(status: %w[requested approved]).where('ends_on >= ?', Date.current).order(:starts_on).first
    end
  end

  def week
    worker = TimeClockService.worker_for(Current.user)
    return redirect_to employee_app_path, alert: 'Ask an administrator to link your staff record.' unless worker

    # Open the sheet covering today, or start one for the pay period (PayRules) without overlapping others.
    today = Date.current
    sheet = worker.timesheets.where('period_start <= ? AND period_end >= ?', today, today).first
    unless sheet
      first, last = People::Timesheet.default_period_for(worker, today)
      sheet = TimesheetWorkflow.new.create(employee_id: worker.id, period_start: first, period_end: last)
      import_finished_shifts(sheet)
    end
    redirect_to people_timesheet_path(sheet)
  rescue TimesheetWorkflow::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to employee_app_path, alert: 'Could not open this week. Refresh and try again.'
  end

  def devices
    response.headers['Cache-Control'] = 'no-store'
    @sessions = EmployeeAppSession.where(user_id: Current.user.id, revoked_at: nil).where('expires_at > ?', Time.current).order(created_at: :desc)
  end

  def revoke
    record = EmployeeAppSession.find_by!(id: params[:id], user_id: Current.user.id)
    record.update!(revoked_at: Time.current)
    redirect_to employee_devices_path, notice: 'Device signed out.'
  end

  def manifest
    render json: { id: '/employee', name: 'Rupert Staff', short_name: 'Rupert', start_url: '/employee', scope: '/', display: 'standalone',
      background_color: '#e6efea', theme_color: '#0e6f72', icons: [192, 512].map { |size| { src: "/employee/icon-#{size}.png?v=rupert-dog-1", sizes: "#{size}x#{size}", type: 'image/png', purpose: 'any maskable' } } }, content_type: 'application/manifest+json'
  end

  def service_worker
    response.headers['Service-Worker-Allowed'] = '/'
    response.headers['Cache-Control'] = 'no-cache'
    send_file Rails.root.join('app/javascript/employee_service_worker.js'), type: 'application/javascript', disposition: 'inline'
  end

  private

  # A new week starts from the clock: finished shifts are imported so staff check rather than type.
  # A pending correction blocks the import; the sheet still opens and says what is waiting.
  def import_finished_shifts(sheet)
    return unless sheet.unimported_shift_count.positive?

    TimesheetWorkflow.new.change(sheet, :import_shifts)
  rescue TimesheetWorkflow::Error, ActiveRecord::RecordInvalid
    nil
  end
end
