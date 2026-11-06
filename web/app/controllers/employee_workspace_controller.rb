# frozen_string_literal: true

# Personal workspace: every record starts from the signed-in worker link,
# never from an employee/user/tenant identifier supplied by the browser.
class EmployeeWorkspaceController < AuthenticatedController
  layout 'employee'
  before_action :private_response
  before_action :require_worker
  rescue_from Date::Error, ArgumentError, with: :invalid_range

  # GET /employee/reports?range=…&from=YYYY-MM-DD&to=YYYY-MM-DD — the signed-in worker's own
  # hours, estimated pay and time off for a preset or custom range (up to one year). Dates are
  # business days in the app time zone. Unusable dates are rejected on this page with the reason,
  # showing the default week instead; the CSV answers 422 with the same reason.
  def reports
    load_report_data
    return reject_report_range if @range_error

    respond_to do |format|
      format.html
      format.csv do
        leave = params[:kind] == 'time_off'
        send_data(leave ? @summary.time_off_csv : @summary.csv, filename: "my-#{leave ? 'time-off' : 'hours'}-#{@from}-#{@to}.csv", type: 'text/csv')
      end
    end
  end

  def report_problem
    values = params.require(:work_report).permit(:kind, :details, :request_key)
    @work_report = @worker.work_reports.find_by(request_key: values[:request_key]) if values[:request_key].present?
    return redirect_to employee_reports_path(anchor: 'problems'), notice: 'Your report is already saved.' if @work_report

    @work_report = @worker.work_reports.new(values)
    @work_report.requester = Current.user
    if @work_report.save
      ActivityLogger.log('employee_work_report_created', subject: @work_report, details: 'Private staff problem report saved; awaiting review.')
      redirect_to employee_reports_path(anchor: 'problems'), notice: 'Your report was saved for administrator review.'
    else
      load_report_data
      render :reports, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to employee_reports_path(anchor: 'problems'), notice: 'Your report is already saved.'
  end

  # GET /employee/schedule?week=YYYY-MM-DD[&team=1]  Posted shifts only: mine, open shifts I can pick up,
  # and (with team=1) colleagues' times at my stores. Drafts never appear here.
  # GET /employee/schedule.ics?token=…  the same person's posted shifts for a calendar app.
  def schedule
    if request.format.ics?
      return head(:unauthorized) unless EmployeeScheduleFeed.valid?(@worker, params[:token].to_s)

      return send_data(EmployeeScheduleFeed.ics(@worker), type: 'text/calendar', filename: 'my-shifts.ics')
    end

    load_schedule_week
    @shifts = @worker.scheduled_shifts.live.published.between(@week, @week + 6).chronological.includes(:location, :position).to_a
    @requests = @worker.leave_requests.where(status: %w[requested approved]).where('starts_on <= ? AND ends_on >= ?', @week + 6, @week).to_a
    @open_shifts = People::ScheduledShift.open_shifts.published.between(@week, @week + 6).chronological.includes(:location, :position)
      .select { |s| @worker.works_at?(s.location_id) && s.starts_at > Time.current }
    @team = params[:team].to_s == '1'
    @team_shifts = if @team
      People::ScheduledShift.live.published.assigned.between(@week, @week + 6).where.not(employee_id: @worker.id)
        .chronological.includes(:employee, :location).select { |s| @worker.works_at?(s.location_id) }
    else
      []
                   end
    @blackouts = People::BlackoutDate.overlapping(@week, @week + 6).to_a.select { |b| b.location_id.nil? || @worker.works_at?(b.location_id) }
    @live_trades = People::ShiftTrade.live.where(scheduled_shift_id: @shifts.map(&:id)).index_by(&:scheduled_shift_id)
    @swap_candidates = People::ScheduledShift.live.published.assigned.where.not(employee_id: @worker.id).where('starts_at > ?', Time.current)
      .where('starts_at < ?', 6.weeks.from_now).chronological.includes(:employee).select { |s| @worker.works_at?(s.location_id) }
    @feed_url = employee_schedule_url(format: :ics, token: EmployeeScheduleFeed.token(@worker))
  end

  def time_off
    @month = params[:month].present? ? Date.strptime("#{params[:month]}-01", '%Y-%m-%d') : Date.current.beginning_of_month
    raise ArgumentError, 'Choose a valid calendar month.' unless (1900..2100).cover?(@month.year) && (params[:month].blank? || params[:month] == @month.strftime('%Y-%m'))
    @summary = EmployeeWorkSummary.new(employee: @worker, from: @month, to: @month.end_of_month)
    @requests = @worker.leave_requests.order(starts_on: :desc).limit(100)
    @balances = People::LeaveRequest::LEAVE_TYPES.reject { |t| t == 'unpaid' }.map { |type| @worker.leave_balance(type, Date.current.year) }
    @rules = TimeRules.for(@worker.location_ids.first)
    @blackouts = People::BlackoutDate.upcoming.to_a.select { |b| b.location_id.nil? || @worker.works_at?(b.location_id) }
    @request ||= @worker.leave_requests.new(leave_type: 'vacation', starts_on: Date.current, ends_on: Date.current)
    @request_key = SecureRandom.uuid
  end

  def request_time_off
    values = params.require(:leave_request).permit(:leave_type, :starts_on, :ends_on, :hours, :reason, :request_key)
    existing = values[:request_key].present? && @worker.leave_requests.find_by(request_key: values[:request_key])
    return redirect_to(employee_time_off_path, notice: t('time.time_off.already_sent')) if existing

    @request = @worker.leave_requests.new(values)
    @request.hours = default_hours_for(@request) if @request.hours.blank? && @request.leave_type != 'unpaid' && @request.starts_on && @request.ends_on
    @request.valid?
    @request.errors.add(:ends_on, 'must be in the same calendar year; send a separate request for each year') if @request.starts_on && @request.ends_on && @request.starts_on.year != @request.ends_on.year
    if @request.errors.empty? && @request.save
      ActivityLogger.log('leave_requested', subject: @request, details: 'Staff self-service request; awaiting manager review.')
      TimeNotifier.approval_needed(TimeNotifier.reviewers_for('leave.write', location_id: @worker.location_ids.first),
        what: "time off #{@request.starts_on.strftime('%b %-d')}#{" – #{@request.ends_on.strftime('%b %-d')}" if @request.ends_on != @request.starts_on} (#{@request.leave_type})",
        who: @worker.name, url: people_leave_request_path(@request), key: "leave:#{@request.id}")
      redirect_to employee_time_off_path, notice: t('time.time_off.sent')
    else
      time_off
      render :time_off, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to employee_time_off_path, notice: t('time.time_off.already_sent')
  end

  def cancel_time_off
    request = @worker.leave_requests.find(params[:id])
    if request.requested? && LeaveRequestWorkflow.change(request, :cancel, self_service: true)
      redirect_to employee_time_off_path, notice: t('time.time_off.cancelled')
    else
      redirect_to employee_time_off_path, alert: t('time.time_off.reviewed_already')
    end
  end

  # Hours off for a request: the person's posted shifts on those days, or 8 h per weekday.
  def default_hours_for(request)
    planned = @worker.scheduled_shifts.live.between(request.starts_on, request.ends_on).sum(&:paid_hours)
    return planned.round(2) if planned.positive?

    (request.starts_on..request.ends_on).count { |d| !d.saturday? && !d.sunday? } * 8
  end
  helper_method :default_hours_for

  private

  def load_schedule_week
    day = params[:week].present? ? Date.iso8601(params[:week]) : Date.current
    raise ArgumentError, 'Choose a valid week.' unless (1900..2100).cover?(day.year)

    @week = day.beginning_of_week
  end

  def load_report_data
    @from, @to, @range_error = report_range
    @summary = EmployeeWorkSummary.new(employee: @worker, from: @from, to: @to)
    @payslips = @worker.payslips.joins(:pay_run).where(pay_runs: { tenant_id: Current.tenant_id, status: %w[finalized paid] })
      .where('pay_runs.period_start <= ? AND pay_runs.period_end >= ?', @to, @from).includes(:pay_run).order('pay_runs.period_end DESC')
    @work_reports = @worker.work_reports.includes(:reviewer).order(created_at: :desc).limit(50)
    @work_report ||= @worker.work_reports.new(request_key: SecureRandom.uuid, kind: 'time')
  end

  # [from, to, problem]: the requested dates, or this week plus the reason they were refused.
  def report_range
    default = [Date.current.beginning_of_week, Date.current.end_of_week]
    range = TimeRangePicker.resolve(params)
    from = range.from || default.first
    to = range.to || default.last
    problem = EmployeeWorkSummary.range_problem(from, to)
    problem ? [*default, problem] : [from, to, nil]
  rescue Date::Error
    [*default, 'Enter the start and end dates as real calendar dates.']
  end

  def reject_report_range
    respond_to do |format|
      format.html do
        flash.now[:alert] = "#{@range_error} Showing this week instead."
        render :reports, status: :unprocessable_entity
      end
      format.csv { render plain: @range_error, status: :unprocessable_entity }
    end
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
  end

  def require_worker
    @worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
    # gate: the signed-in person's own linked staff record; every page reads only @worker's data
    return skip_authorization if @worker

    redirect_to employee_app_path, alert: 'Ask an administrator to link your staff record before using your personal workspace.'
  end

  def invalid_range
    redirect_to employee_app_path, alert: 'Choose valid dates, with no more than one year in a report.'
  end
end
