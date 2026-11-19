# frozen_string_literal: true

module People
  # When each person can work, by weekday. Managers edit anyone here; a worker edits their own
  # from the Schedule tab (EmployeeAvailabilityController).
  class AvailabilitiesController < AuthenticatedController
    before_action -> { require_time_feature(:scheduling) }
    before_action { authorize(:module, :schedule_write?) }

    def index
      @employees = People::Employee.active.ordered.includes(:availabilities).to_a
      @employee = params[:employee_id].present? ? People::Employee.active.find(params[:employee_id]) : @employees.first
      @blocks = @employee ? @employee.availabilities.ordered.to_a : []
      @block = People::EmployeeAvailability.new(kind: 'unavailable', start_minute: 0, end_minute: 1440)
    end

    def create
      employee = People::Employee.active.find(params[:employee_id])
      block = employee.availabilities.new(availability_params)
      if block.save
        ActivityLogger.log('availability_added', subject: block, details: "#{employee.name}: #{block.weekday_label} #{block.time_label} #{block.kind}")
        redirect_to people_availabilities_path(employee_id: employee.id), notice: 'Availability saved.'
      else
        redirect_to people_availabilities_path(employee_id: employee.id), alert: block.errors.full_messages.to_sentence
      end
    end

    def destroy
      block = People::EmployeeAvailability.find(params[:id])
      block.destroy!
      redirect_to people_availabilities_path(employee_id: block.employee_id), notice: 'Availability removed.'
    end

    private

    def availability_params
      raw = params.require(:employee_availability).permit(:weekday, :kind, :start_time, :end_time, :note, :all_day)
      AvailabilityParams.normalize(raw)
    end
  end
end
