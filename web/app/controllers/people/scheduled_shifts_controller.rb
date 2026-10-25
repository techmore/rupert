# frozen_string_literal: true

module People
  # Managers plan shifts here; employees read their own in the personal workspace.
  class ScheduledShiftsController < AuthenticatedController
    before_action :set_shift, only: %i[edit update destroy]
    rescue_from Date::Error, with: :invalid_week

    def index
      authorize(:module, :schedule_read?)
      day = params[:week].present? ? Date.iso8601(params[:week]) : Date.current
      raise Date::Error unless (1900..2100).cover?(day.year)

      @week = day.beginning_of_week
      @locations = Location.for_shifts.to_a
      @location_id = params[:location_id].presence&.to_s
      @shifts = People::ScheduledShift.between(@week, @week + 6).chronological.includes(:employee, :location)
      @shifts = @shifts.where(location_id: @location_id) if @location_id
      @by_employee = @shifts.group_by(&:employee).sort_by { |employee, _| [employee.last_name.to_s, employee.first_name.to_s] }
      leave = People::LeaveRequest.where(status: 'approved', employee_id: @shifts.map(&:employee_id).uniq)
        .where('starts_on <= ? AND ends_on >= ?', @week + 7, @week).to_a
      @on_leave = @shifts.select do |shift|
        leave.any? { |item| item.employee_id == shift.employee_id && item.starts_on <= shift.ends_at.to_date && item.ends_on >= shift.starts_at.to_date }
      end.map(&:id).to_set
      load_hours_warnings
      load_planned_and_worked
    end

    # Copies last week's shifts into the week shown (#469). Overlaps are skipped, never replaced.
    def copy_last_week
      authorize(:module, :schedule_write?)
      week = Date.iso8601(params[:week].to_s).beginning_of_week
      raise Date::Error unless (1900..2100).cover?(week.year)

      copied, skipped = People::ScheduledShift.copy_week_forward(week)
      ActivityLogger.log('scheduled_week_copied', details: "#{(week - 7).strftime('%b %-d')} → #{week.strftime('%b %-d, %Y')}: #{copied.size} copied, #{skipped} skipped")
      message = copied.empty? && skipped.zero? ? 'Last week has no shifts to copy.' : "Copied #{helpers.pluralize(copied.size, 'shift')} from last week."
      message += " Skipped #{skipped}: they overlap a shift already planned or the person is no longer active." if skipped.positive?
      leave = copied.count { |shift| shift.approved_leave.exists? }
      message += " #{helpers.pluralize(leave, 'copied shift')} #{leave == 1 ? 'falls' : 'fall'} on approved leave." if leave.positive?
      redirect_to(people_scheduled_shifts_path(week: week.iso8601), notice: message)
    end

    def new
      authorize(:module, :schedule_write?)
      day = params[:date].present? ? Date.iso8601(params[:date]) : Date.current
      @shift = People::ScheduledShift.new(employee_id: params[:employee_id], location_id: params[:location_id].presence, starts_at: day.in_time_zone + 9.hours, ends_at: day.in_time_zone + 17.hours)
      load_employees
    end

    def create
      authorize(:module, :schedule_write?)
      @shift = People::ScheduledShift.new(shift_params)
      if @shift.save
        ActivityLogger.log('scheduled_shift_created', subject: @shift, details: shift_details)
        redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: with_planning_warnings('Shift scheduled.'))
      else
        load_employees
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :schedule_write?)
      load_employees
    end

    def update
      authorize(:module, :schedule_write?)
      if @shift.update(shift_params)
        ActivityLogger.log('scheduled_shift_updated', subject: @shift, details: shift_details)
        redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: with_planning_warnings('Shift updated.'))
      else
        load_employees
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :schedule_write?)
      @shift.destroy!
      ActivityLogger.log('scheduled_shift_deleted', subject: @shift, details: shift_details)
      redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: 'Shift removed.')
    end

    private

    def set_shift
      @shift = People::ScheduledShift.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def load_employees
      @employees = People::Employee.active.ordered
      @locations = Location.for_shifts.to_a
      @locations.unshift(@shift.location) if @shift.location && @locations.exclude?(@shift.location)
    end

    def shift_params
      params.require(:scheduled_shift).permit(:employee_id, :starts_at, :ends_at, :role_label, :notes, :location_id)
    end

    def shift_details
      "#{@shift.employee&.full_name} · #{@shift.starts_at.strftime('%b %-d %-l:%M %p')} – #{@shift.ends_at.strftime('%-l:%M %p')}#{" · #{@shift.location.name}" if @shift.location}"
    end

    # Warnings only: the shift is already saved.
    def with_planning_warnings(message)
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

    # Pay weeks run Thursday-Wednesday, so a Monday-Sunday grid week touches two.
    # Planned hours only; this does not calculate pay.
    def load_hours_warnings
      @pay_weeks = [EmployeePayWeek.week_start(@week), EmployeePayWeek.week_start(@week + 6)]
      nearby = @nearby = People::ScheduledShift.between(@pay_weeks.first, @pay_weeks.last + 6).includes(:employee).to_a
      limit = People::ScheduledShift::PLANNED_HOURS_LIMIT
      @over_hours = nearby.group_by(&:employee).filter_map do |employee, list|
        weeks = @pay_weeks.filter_map do |start|
          total = list.sum { |shift| shift.hours_within(start.in_time_zone, (start + 7).in_time_zone) }
          [start, total] if total > limit
        end
        [employee, weeks] if weeks.any?
      end.sort_by { |employee, _| [employee.last_name.to_s, employee.first_name.to_s] }.to_h
      shown = @shifts.map(&:id).to_set
      @short_rest = {}
      nearby.group_by(&:employee_id).each_value do |list|
        list.sort_by(&:starts_at).each_cons(2) do |previous, shift|
          gap = (shift.starts_at - previous.ends_at) / 3600.0
          @short_rest[shift.id] = gap if gap < People::ScheduledShift::MIN_REST_HOURS && shown.include?(shift.id)
        end
      end
    end

    # Planned against worked for the Monday-Sunday week shown (#469 gap 10). Planned
    # comes from shifts at every store (reusing the rows loaded for the warnings);
    # worked from Rupert clock punches, which record no store. An open punch, or no
    # punch at all that week, makes worked hours unknown: never counted as zero.
    def load_planned_and_worked
      from = @week.in_time_zone
      to = (@week + 7).in_time_zone
      planned = Hash.new(0.0)
      @nearby.each { |shift| planned[shift.employee_id] += shift.hours_within(from, to) }
      people = @by_employee.map(&:first)
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
