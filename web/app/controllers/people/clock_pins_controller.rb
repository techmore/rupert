# frozen_string_literal: true

module People
  # A staff member's clock PIN from the HR page: set one for them, or reset it so they choose a new
  # one at the register. Managers never see the digits; only a digest is stored.
  class ClockPinsController < AuthenticatedController
    before_action { authorize(:module, :hr_write?) }
    before_action :load_employee

    def create
      TimeClockService.set_clock_pin!(@employee, params[:pin], confirmation: params[:pin_confirmation])
      ActivityLogger.log('clock_pin.set', subject: @employee, details: { by: Current.user.id }.to_json)
      redirect_to people_employee_path(@employee, anchor: 'access'), notice: "Clock PIN saved for #{@employee.first_name}."
    rescue ArgumentError => e
      redirect_to people_employee_path(@employee, anchor: 'access'), alert: e.message
    end

    def reset
      @employee.update!(pin_digest: nil, pin_set_at: nil, pin_failed_count: 0, pin_locked_until: nil)
      ActivityLogger.log('clock_pin.reset', subject: @employee, details: { by: Current.user.id }.to_json)
      redirect_to people_employee_path(@employee, anchor: 'access'), notice: "Clock PIN cleared. #{@employee.first_name} chooses a new one at the register."
    end

    private

    def load_employee
      @employee = People::Employee.find(params[:employee_id])
    end
  end
end
