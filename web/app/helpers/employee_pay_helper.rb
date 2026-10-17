module EmployeePayHelper
  def employee_pay_header
    return unless Current.user && !@preview

    worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
    return unless worker

    demo = worker.source == 'demo_pay'
    period = demo ? EmployeeEarningsPeriod.demo : EmployeeEarningsPeriod.where(employee_id: worker.id).order(period_end: :desc).first
    render 'shared/employee_pay_header', period: period, demo: demo
  end
end
