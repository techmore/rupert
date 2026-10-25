# frozen_string_literal: true

module People
  # Payroll: a pay run covers one pay period with a payslip per employee,
  # generated from approved timesheets. Draft -> finalized (totals locked) ->
  # paid (money out).
  class PayRunsController < AuthenticatedController
    before_action :set_pay_run, only: %i[show finalize pay generate_payslips add_payslip remove_payslip]

    def index
      authorize(:module, :payroll_read?)
      @status = params[:status].presence || 'all'
      @pay_runs = People::PayRun.by_status(@status).recent(100).includes(:payslips)
      @year = params[:year].presence || Date.current.year.to_s
      # Stored totals are encrypted (#421): pluck decrypts them and Ruby adds them up.
      @annual_gross = People::PayRun.where(period_start: Date.new(@year.to_i, 1, 1)..Date.new(@year.to_i, 12, 31))
                                    .pluck(:total_gross_cents).sum(&:to_i)
    end

    def show
      authorize(@pay_run)
      respond_to do |format|
        format.html do
          @slip = People::Payslip.new(pay_run: @pay_run)
          @employees = People::Employee.ordered
        end
        format.csv do
          ActivityLogger.log('data_exported', subject: @pay_run, details: "Pay run CSV · #{@pay_run.payslips.count} payslips")
          send_data PayRunCsv.generate(@pay_run), filename: "pay-run-#{@pay_run.id}-#{@pay_run.period_start.iso8601}.csv", type: 'text/csv'
        end
      end
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
        ActivityLogger.log('pay_run_created', subject: @pay_run, details: "#{@pay_run.payslips.count} payslips")
        redirect_to(people_pay_run_path(@pay_run), notice: "Pay run created with #{@pay_run.payslips.count} payslips.")
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    # Rebuild payslips from approved timesheets (draft runs only).
    def generate_payslips
      authorize(:module, :payroll_write?)
      unless @pay_run.draft?
        return redirect_to(people_pay_run_path(@pay_run),
          alert: 'Only draft pay runs can be regenerated.')
      end

      People::PayrollCalculator.generate!(@pay_run)
      missing = @pay_run.employees_without_rate.to_a
      if missing.any?
        flash[:alert] = "No payslip for #{missing.map(&:name).to_sentence}: approved hours but no pay rate for this period. Add a pay rate and regenerate."
      end
      redirect_to(people_pay_run_path(@pay_run), notice: 'Payslips regenerated from approved timesheets.')
    end

    # Add a manual payslip (bonus, commission, off-cycle).
    def add_payslip
      authorize(:module, :payroll_write?)
      unless @pay_run.draft?
        return redirect_to(people_pay_run_path(@pay_run),
          alert: 'Only draft pay runs can be edited.')
      end

      @slip = @pay_run.payslips.new(add_payslip_params)
      if @slip.save
        @pay_run.reload.update!(total_gross_cents: @pay_run.total_gross_cents,
          total_net_cents: @pay_run.total_net_cents)
        redirect_to(people_pay_run_path(@pay_run), notice: 'Payslip added.')
      else
        @pay_run.payslips.reload
        @employees = People::Employee.ordered
        render(:show, status: :unprocessable_entity)
      end
    end

    def remove_payslip
      authorize(:module, :payroll_write?)
      unless @pay_run.draft?
        return redirect_to(people_pay_run_path(@pay_run),
          alert: 'Only draft pay runs can be edited.')
      end

      @pay_run.payslips.find_by(id: params[:payslip_id])&.destroy
      @pay_run.update!(total_gross_cents: @pay_run.total_gross_cents, total_net_cents: @pay_run.total_net_cents)
      redirect_to(people_pay_run_path(@pay_run), notice: 'Payslip removed.')
    end

    def finalize
      authorize(:module, :payroll_write?)
      unless @pay_run.draft?
        return redirect_to(people_pay_run_path(@pay_run),
          alert: @pay_run.paid? ? 'This pay run is already paid.' : 'This pay run is already finalized.')
      end
      if @pay_run.payslips.empty?
        return redirect_to(people_pay_run_path(@pay_run),
          alert: 'Add at least one payslip first.')
      end

      People::PayrollCalculator.apply_default_deductions(@pay_run)
      # The amounts are encrypted (#421), so they are added up in Ruby.
      @pay_run.update!(total_gross_cents: @pay_run.total_gross_cents, total_net_cents: @pay_run.total_net_cents)
      @pay_run.finalize!
      ActivityLogger.log('pay_run_finalized', subject: @pay_run,
        details: "$#{format('%.2f', @pay_run.total_net_cents / 100.0)}")
      redirect_to(people_pay_run_path(@pay_run), notice: 'Pay run finalized.')
    end

    def pay
      authorize(:module, :payroll_write?)
      unless @pay_run.finalized?
        return redirect_to(people_pay_run_path(@pay_run),
          alert: 'Finalize the pay run before paying.')
      end

      @pay_run.update!(paid_on: Date.today)
      @pay_run.pay! if @pay_run.may_pay?
      ActivityLogger.log('pay_run_paid', subject: @pay_run, details: @pay_run.paid_on.to_s)
      redirect_to(people_pay_run_path(@pay_run), notice: 'Pay run marked paid.')
    end

    private

    def set_pay_run
      @pay_run = People::PayRun.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def pay_run_params
      params.require(:pay_run).permit(:name, :period_start, :period_end, :notes)
    end

    # The form takes dollars (`gross`, `deductions`); `gross_cents`/`deductions_cents` are still accepted from older
    # clients. Net is gross less deductions.
    def add_payslip_params
      raw = params.require(:payslip).permit(:employee_id, :pay_rate_id, :hours, :gross, :deductions, :gross_cents, :deductions_cents, :notes)
      attrs = raw.except(:gross, :deductions).to_h
      attrs[:gross_cents] = dollars_to_cents(raw[:gross]) if raw[:gross].present?
      attrs[:deductions_cents] = dollars_to_cents(raw[:deductions]) if raw[:deductions].present?
      attrs[:deductions_cents] = 0 if attrs[:deductions_cents].blank?
      attrs[:net_cents] = attrs[:gross_cents].to_i - attrs[:deductions_cents].to_i if attrs[:gross_cents].present?
      attrs
    end

    def dollars_to_cents(value)
      (BigDecimal(value.to_s.delete(',$ ')) * 100).round.to_i
    rescue ArgumentError
      -1 # fails the payslip's "not negative" validation with a message instead of saving a wrong amount
    end
  end
end
