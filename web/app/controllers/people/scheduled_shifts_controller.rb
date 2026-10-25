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
      @shifts = People::ScheduledShift.between(@week, @week + 6).chronological.includes(:employee)
      @by_employee = @shifts.group_by(&:employee).sort_by { |employee, _| [employee.last_name.to_s, employee.first_name.to_s] }
      leave = People::LeaveRequest.where(status: 'approved', employee_id: @shifts.map(&:employee_id).uniq)
        .where('starts_on <= ? AND ends_on >= ?', @week + 7, @week).to_a
      @on_leave = @shifts.select do |shift|
        leave.any? { |item| item.employee_id == shift.employee_id && item.starts_on <= shift.ends_at.to_date && item.ends_on >= shift.starts_at.to_date }
      end.map(&:id).to_set
      load_hours_warnings
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
      @shift = People::ScheduledShift.new(employee_id: params[:employee_id], starts_at: day.in_time_zone + 9.hours, ends_at: day.in_time_zone + 17.hours)
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
    end

    def shift_params
      params.require(:scheduled_shift).permit(:employee_id, :starts_at, :ends_at, :role_label, :notes)
    end

    def shift_details
      "#{@shift.employee&.full_name} · #{@shift.starts_at.strftime('%b %-d %-l:%M %p')} – #{@shift.ends_at.strftime('%-l:%M %p')}"
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
      nearby = People::ScheduledShift.between(@pay_weeks.first, @pay_weeks.last + 6).includes(:employee).to_a
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
