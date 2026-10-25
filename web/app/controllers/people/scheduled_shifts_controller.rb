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
        redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: with_leave_warning('Shift scheduled.'))
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
        redirect_to(people_scheduled_shifts_path(week: @shift.starts_at.to_date.iso8601), notice: with_leave_warning('Shift updated.'))
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

    def with_leave_warning(message)
      return message unless @shift.approved_leave.exists?

      "#{message} Note: #{@shift.employee.full_name} has approved leave on this day."
    end

    def invalid_week
      redirect_to(people_scheduled_shifts_path, alert: 'Choose a valid week.')
    end
  end
end
