# frozen_string_literal: true

module People
  # Payroll: a pay run covers one pay period with a payslip per employee,
  # generated from approved timesheets. Draft -> finalized (totals locked) ->
  # paid (money out).
  class PayRunsController < AuthenticatedController
    before_action :set_pay_run, only: [:show, :finalize, :pay, :generate_payslips, :add_payslip, :remove_payslip]

    def index
      authorize(:module, :payroll_read?)
      @status = params[:status].presence || "all"
      @pay_runs = People::PayRun.by_status(@status).recent(100).includes(:payslips)
      @year = params[:year].presence || Date.current.year.to_s
      @annual_gross = People::PayRun.where(period_start: Date.new(@year.to_i, 1, 1)..Date.new(@year.to_i, 12, 31)).sum(:total_gross_cents)
    end

    def show
      authorize(@pay_run)
      @slip = People::Payslip.new(pay_run: @pay_run)
      @employees = People::Employee.ordered
    end

    def new
      authorize(:module, :payroll_write?)
      last = People::PayRun.recent(1).first
      start_date = last ? last.period_end + 1 : Date.today.beginning_of_week - 13
      @pay_run = People::PayRun.new(period_start: start_date, period_end: start_date + 13)
    end

    def create
      authorize(:module, :payroll_write?)
      @pay_run = People::PayRun.new(pay_run_params)
      if @pay_run.save
        People::PayrollCalculator.generate!(@pay_run)
        ActivityLogger.log("pay_run_created", subject: @pay_run, details: "#{@pay_run.payslips.count} payslips")
        redirect_to(people_pay_run_path(@pay_run), notice: "Pay run created with #{@pay_run.payslips.count} payslips.")
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    # Rebuild payslips from approved timesheets (draft runs only).
    def generate_payslips
      authorize(:module, :payroll_write?)
      return redirect_to(people_pay_run_path(@pay_run), alert: "Only draft pay runs can be regenerated.") unless @pay_run.draft?

      People::PayrollCalculator.generate!(@pay_run)
      redirect_to(people_pay_run_path(@pay_run), notice: "Payslips regenerated from approved timesheets.")
    end

    # Add a manual payslip (bonus, commission, off-cycle).
    def add_payslip
      authorize(:module, :payroll_write?)
      return redirect_to(people_pay_run_path(@pay_run), alert: "Only draft pay runs can be edited.") unless @pay_run.draft?

      @slip = @pay_run.payslips.new(add_payslip_params)
      if @slip.save
        @pay_run.reload.update!(total_gross_cents: @pay_run.total_gross_cents, total_net_cents: @pay_run.total_net_cents)
        redirect_to(people_pay_run_path(@pay_run), notice: "Payslip added.")
      else
        @pay_run.payslips.reload
        @employees = People::Employee.ordered
        render(:show, status: :unprocessable_entity)
      end
    end

    def remove_payslip
      authorize(:module, :payroll_write?)
      return redirect_to(people_pay_run_path(@pay_run), alert: "Only draft pay runs can be edited.") unless @pay_run.draft?

      @pay_run.payslips.find_by(id: params[:payslip_id])&.destroy
      @pay_run.update!(total_gross_cents: @pay_run.total_gross_cents, total_net_cents: @pay_run.total_net_cents)
      redirect_to(people_pay_run_path(@pay_run), notice: "Payslip removed.")
    end

    def finalize
      authorize(:module, :payroll_write?)
      return redirect_to(people_pay_run_path(@pay_run), alert: "Add at least one payslip first.") if @pay_run.payslips.empty?

      People::PayrollCalculator.apply_default_deductions(@pay_run)
      totals = @pay_run.payslips.pick(Arel.sql("COALESCE(SUM(gross_cents), 0), COALESCE(SUM(net_cents), 0)"))
      @pay_run.update!(total_gross_cents: totals[0], total_net_cents: totals[1])
      @pay_run.finalize! if @pay_run.may_finalize?
      ActivityLogger.log("pay_run_finalized", subject: @pay_run, details: "$#{format("%.2f", @pay_run.total_net_cents / 100.0)}")
      redirect_to(people_pay_run_path(@pay_run), notice: "Pay run finalized.")
    end

    def pay
      authorize(:module, :payroll_write?)
      return redirect_to(people_pay_run_path(@pay_run), alert: "Finalize the pay run before paying.") unless @pay_run.finalized?

      @pay_run.update!(paid_on: Date.today)
      @pay_run.pay! if @pay_run.may_pay?
      ActivityLogger.log("pay_run_paid", subject: @pay_run, details: @pay_run.paid_on.to_s)
      redirect_to(people_pay_run_path(@pay_run), notice: "Pay run marked paid.")
    end

    private

    def set_pay_run
      @pay_run = People::PayRun.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def pay_run_params
      params.require(:pay_run).permit(:name, :period_start, :period_end, :notes)
    end

    def add_payslip_params
      params.require(:payslip).permit(:employee_id, :pay_rate_id, :hours, :gross_cents, :deductions_cents, :notes)
        .tap do |p|
          p[:net_cents] = p[:gross_cents].to_i - p[:deductions_cents].to_i if p[:gross_cents].present?
        end
    end
  end
end
