# frozen_string_literal: true

module People
  # The schedule builder: managers plan a Monday–Sunday week on a drag-and-drop grid, post it to
  # staff, and keep templates. Employees read their own posted shifts in the personal workspace.
  class ScheduledShiftsController < AuthenticatedController
    before_action -> { require_time_feature(:scheduling) }
    before_action :set_shift, only: %i[edit update destroy cancel]
    rescue_from Date::Error, with: :invalid_week

    def index
      authorize(:module, :schedule_read?)
      day = params[:week].present? ? Date.iso8601(params[:week]) : Date.current
      raise Date::Error unless (1900..2100).cover?(day.year)

      @week = day.beginning_of_week
      @locations = Location.for_shifts.to_a
      @location_id = params[:location_id].presence&.to_s
      @schedule = People::ScheduleWeek.new(@week, location_id: @location_id)
      @employees = @schedule.employees
      @positions = People::Position.order(:name).to_a
      @templates = People::ScheduleTemplate.ordered.to_a
      @can_write = Current.user.can?('schedule.write') || Current.user.can?('hr.write')
      @publication = People::SchedulePublication.first_for(@week, @location_id)
      load_planned_and_worked
    end

    # Copies last week's shifts into the week shown (#469). Overlaps are skipped, never replaced.
    def copy_last_week
      authorize(:module, :schedule_write?)
      week = Date.iso8601(params[:week].to_s).beginning_of_week
      raise Date::Error unless (1900..2100).cover?(week.year)

      copied, skipped = People::ScheduledShift.copy_week_forward(week)
      ActivityLogger.log('scheduled_week_copied', details: "#{(week - 7).strftime('%b %-d')} → #{week.strftime('%b %-d, %Y')}: #{copied.size} copied, #{skipped} skipped")
      message = copied.empty? && skipped.zero? ? 'Last week has no shifts to copy.' : "Copied #{helpers.pluralize(copied.size, 'shift')} from last week as drafts."
      message += " Skipped #{skipped}: they overlap a shift already planned or the person is no longer active." if skipped.positive?
      redirect_to(people_scheduled_shifts_path(week: week.iso8601, location_id: params[:location_id].presence), notice: message)
    end

    # Posts the week: stamps every draft shift, records the publication and tells each worker.
    def publish
      authorize(:module, :schedule_write?)
      week = Date.iso8601(params[:week].to_s).beginning_of_week
      result = People::SchedulePublisher.publish_week!(week, location_id: params[:location_id].presence, by: Current.user)
      message = result.published.empty? ? 'Everything this week is already posted.' : "Posted #{helpers.pluralize(result.published.size, 'shift')} to #{helpers.pluralize(result.workers.size, 'person')}."
      if result.short_notice?
        message += " Note: #{result.notice_days.negative? ? 'this week has already started' : "only #{helpers.pluralize(result.notice_days, 'day')} of notice"}; the store asks for #{TimeRules.for(params[:location_id].presence).schedule_notice_days}."
      end
      redirect_to(people_scheduled_shifts_path(week: week.iso8601, location_id: params[:location_id].presence), notice: message)
    end

    def new
      authorize(:module, :schedule_write?)
      day = params[:date].present? ? Date.iso8601(params[:date]) : Date.current
      @shift = People::ScheduledShift.new(employee_id: params[:employee_id], location_id: params[:location_id].presence,
        starts_at: day.in_time_zone + 9.hours, ends_at: day.in_time_zone + 17.hours)
      load_employees
    end

    # HTML: the form. JSON (the builder's quick-add): { shift: {…} } → the cell partial and warnings.
    def create
      authorize(:module, :schedule_write?)
      @shift = People::ScheduledShift.new(shift_params.merge(created_by: Current.user))
      if @shift.save
        ActivityLogger.log('scheduled_shift_created', subject: @shift, details: shift_details)
        respond_to do |format|
          format.html { redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601, location_id: @shift.location_id), notice: with_planning_warnings('Shift added as a draft. Post the week when it is ready.')) }
          format.json { render_cell(@shift, status: :created) }
        end
      else
        respond_to do |format|
          format.html do
            load_employees
            render(:new, status: :unprocessable_entity)
          end
          format.json { render json: { error: @shift.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end

    def edit
      authorize(:module, :schedule_write?)
      load_employees
    end

    # HTML: the form. JSON (drag, resize, reassign): { shift: { starts_at, ends_at, employee_id } }.
    def update
      authorize(:module, :schedule_write?)
      previous_employee = @shift.employee
      was_published = @shift.published?
      if @shift.update(shift_params.merge(last_changed_at: Time.current))
        ActivityLogger.log('scheduled_shift_updated', subject: @shift, details: shift_details)
        People::SchedulePublisher.notify_change(@shift, change: 'changed', previous_employee: previous_employee) if was_published
        respond_to do |format|
          format.html { redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601, location_id: @shift.location_id), notice: with_planning_warnings('Shift updated.')) }
          format.json { render_cell(@shift) }
        end
      else
        respond_to do |format|
          format.html do
            load_employees
            render(:edit, status: :unprocessable_entity)
          end
          format.json { render json: { error: @shift.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end

    # A posted shift is cancelled (kept, marked, worker told); a draft is simply removed.
    def destroy
      authorize(:module, :schedule_write?)
      if @shift.published?
        @shift.update!(cancelled_at: Time.current, last_changed_at: Time.current)
        People::SchedulePublisher.notify_change(@shift, change: 'cancelled')
        ActivityLogger.log('scheduled_shift_cancelled', subject: @shift, details: shift_details)
        notice = 'Shift cancelled. The person has been told.'
      else
        @shift.destroy!
        ActivityLogger.log('scheduled_shift_deleted', subject: @shift, details: shift_details)
        notice = 'Draft shift removed.'
      end
      respond_to do |format|
        format.html { redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601, location_id: @shift.location_id), notice: notice) }
        format.json { render json: { ok: true, id: @shift.id, cancelled: @shift.cancelled? } }
      end
    end
    alias cancel destroy

    private

    def set_shift
      @shift = People::ScheduledShift.live.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def load_employees
      @employees = People::Employee.active.ordered
      @positions = People::Position.order(:name).to_a
      @locations = Location.for_shifts.to_a
      @locations.unshift(@shift.location) if @shift.location && @locations.exclude?(@shift.location)
    end

    def shift_params
      permitted = params.require(:scheduled_shift).permit(:employee_id, :starts_at, :ends_at, :role_label, :notes, :location_id, :position_id, :break_minutes, :open)
      permitted[:employee_id] = nil if permitted.delete(:open).to_s == '1' || permitted[:employee_id].to_s == 'open'
      %i[location_id position_id].each { |key| permitted[key] = nil if permitted.key?(key) && permitted[key].blank? }
      permitted
    end

    # The builder re-renders the one cell it changed, plus warnings and the labour line.
    def render_cell(shift, status: :ok)
      week = shift.starts_at.to_date.beginning_of_week
      schedule = People::ScheduleWeek.new(week, location_id: params[:location_id].presence)
      html = render_to_string(partial: 'people/scheduled_shifts/shift', formats: [:html], locals: { shift: shift, warnings: schedule.warnings_for(shift), can_write: true, location_id: params[:location_id].presence })
      render json: { id: shift.id, employee_id: shift.employee_id, date: shift.starts_at.to_date.iso8601, html: html,
                     warnings: schedule.warnings_for(shift).map(&:to_h), labor: labor_json(schedule) }, status: status
    end

    def labor_json(schedule)
      total = schedule.labor_total
      { days: schedule.labor.transform_keys(&:iso8601).transform_values { |row| row.merge(percent: People::ScheduleWeek.percent(row[:cost_cents], row[:sales_cents])) },
        total: total.merge(percent: People::ScheduleWeek.percent(total[:cost_cents], total[:sales_cents])) }
    end

    def shift_details
      "#{@shift.employee&.full_name || 'Open shift'} · #{@shift.starts_at.strftime('%b %-d %-l:%M %p')} – #{@shift.ends_at.strftime('%-l:%M %p')}#{" · #{@shift.location.name}" if @shift.location}"
    end

    # Warnings only: the shift is already saved.
    def with_planning_warnings(message)
      return message if @shift.employee.nil?

      name = @shift.employee.full_name
      notes = []
      notes << "#{name} has approved leave on this day." if @shift.approved_leave.exists?
      @shift.pay_weeks_over_limit.each do |start, total|
        notes << "#{name} is planned for #{hours_label(total)} hours in the pay week #{pay_week_label(start)}, over #{People::ScheduledShift::PLANNED_HOURS_LIMIT}."
      end
      @shift.short_rests.each do |gap|
        notes << "Only #{hours_label(gap)} hours between this shift and another for #{name} (less than #{People::ScheduledShift::MIN_REST_HOURS})."
      end
      notes.empty? ? message : "#{message} Note: #{notes.join(' ')}"
    end

    # Planned against worked for the week shown (#469 gap 10). Worked comes from Rupert clock
    # punches; an open punch, or none that week, makes worked hours unknown, never zero.
    def load_planned_and_worked
      from = @week.in_time_zone
      to = (@week + 7).in_time_zone
      planned = Hash.new(0.0)
      @schedule.shifts.each { |shift| planned[shift.employee_id] += shift.hours_within(from, to) if shift.employee_id }
      people = @employees.select { |e| planned.key?(e.id) }
      punches = ClockShift.where.not(employee_id: nil).where('started_at < ? AND (ended_at IS NULL OR ended_at > ?)', to, from)
      punches = punches.where(employee_id: people.map(&:id)) if @location_id
      worked = {}
      open = Set.new
      punches.pluck(:employee_id, :started_at, :ended_at).each do |employee_id, started_at, ended_at|
        open << employee_id if ended_at.nil?
        span = ended_at && [([ended_at, to].min - [started_at, from].max) / 3600.0, 0].max
        worked[employee_id] = worked.fetch(employee_id, 0.0) + span.to_f
      end
      missing = worked.keys - people.map(&:id)
      people += People::Employee.where(id: missing).to_a if missing.any?
      @planned_worked = people.uniq.sort_by { |employee| [employee.last_name.to_s, employee.first_name.to_s] }.map do |employee|
        known = worked.key?(employee.id) && open.exclude?(employee.id)
        reason = ('Still clocked in' if open.include?(employee.id)) || ('No punches' unless worked.key?(employee.id))
        { employee: employee, planned: planned[employee.id], worked: (worked[employee.id] if known), reason: reason }
      end
    end

    # "+1.5", "−2", "0": a real minus sign for fewer hours worked than planned.
    def hours_difference(value)
      rounded = value.round(2)
      return '0' if rounded.zero?

      "#{rounded.negative? ? '−' : '+'}#{hours_label(rounded.abs)}"
    end
    helper_method :hours_difference

    def hours_label(value)
      helpers.number_with_precision(value, precision: 2, strip_insignificant_zeros: true)
    end
    helper_method :hours_label

    def pay_week_label(start)
      "#{start.strftime('%a %b %-d')} – #{(start + 6).strftime('%a %b %-d')}"
    end
    helper_method :pay_week_label

    def invalid_week
      redirect_to(people_scheduled_shifts_path, alert: 'Choose a valid week.')
    end
  end
end
