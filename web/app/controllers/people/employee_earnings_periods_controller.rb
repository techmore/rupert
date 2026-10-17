module People
  class EmployeeEarningsPeriodsController < AuthenticatedController
    before_action -> { authorize(:module, :payroll_write?) }
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def new
      @period = EmployeeEarningsPeriod.new(period_start: Date.current.beginning_of_week - 7, period_end: Date.current.beginning_of_week - 1)
      @employees = People::Employee.where.not(source: 'demo_pay').or(People::Employee.where(source: nil)).ordered
    end

    def create
      @period = EmployeeEarningsPeriod.new(params.require(:employee_earnings_period).permit(:employee_id, :period_start, :period_end, :hours, *EmployeeEarningsPeriod::COMPONENTS.map { |name| "#{name}_cents" }))
      @period.employee = People::Employee.where.not(source: 'demo_pay').or(People::Employee.where(source: nil)).find(@period.employee_id)
      @period.reviewed_at = Time.current
      if @period.save
        ActivityLogger.log('employee_earnings_reviewed', subject: @period, details: 'Reviewed gross earnings published to employee pay header.')
        redirect_to new_people_employee_earnings_period_path, notice: 'Reviewed earnings published to the employee pay header.'
      else
        @employees = People::Employee.ordered
        render :new, status: :unprocessable_entity
      end
    end
  end
end
