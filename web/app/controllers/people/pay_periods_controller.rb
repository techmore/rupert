# frozen_string_literal: true

module People
  # Pay periods as payroll sees them: open while hours and tips can change, locked when a payroll
  # operator closes them, exported once the file is produced. Periods come from the pay rules and
  # are created on demand; nothing here moves money.
  class PayPeriodsController < AuthenticatedController
    before_action :prevent_caching
    before_action :set_period, except: :index

    def index
      authorize(:module, :payroll_read?)
      rules = PayRules.current
      current = rules.period_range(Date.current).first
      starts = (0..7).map { |n| current - (n * rules.period_days) }
      starts.each { |start| PayPeriod.for_date(start, rules: rules) }
      @periods = PayPeriod.where(starts_on: [starts.min, Date.new(1970)].min..).order(starts_on: :desc).to_a
      @current_start = current
    end

    def show
      authorize(:module, :payroll_read?)
      @summary = People::PayPeriodSummary.new(@period, employees: People::StoreScope.employees_for(Current.user, base: People::Employee.all))
      @rows = @summary.rows
      @warnings = @summary.warnings
      @adjustment = PayPeriodAdjustment.new(pay_period: @period)
      @employees = People::Employee.active.ordered
      respond_to do |format|
        format.html
        format.csv do
          authorize(:module, :payroll_write?)
          csv = PayrollExport.csv(@period, summary: @summary)
          sha = PayrollExport.sha256(csv)
          @period.mark_exported!(by: Current.user, sha256: sha) if @period.locked?
          ActivityLogger.log('payroll_exported', subject: @period, details: "#{@period.label} · #{@rows.size} employees · sha256 #{sha}#{' (period still open: estimate only)' if @period.open?}")
          send_data csv, filename: PayrollExport.filename(@period), type: 'text/csv'
        end
      end
    end

    def lock
      authorize(:module, :payroll_write?)
      summary = People::PayPeriodSummary.new(@period)
      blocking = summary.blocking_warnings
      if blocking.any? && params[:lock_anyway] != '1'
        return redirect_to people_pay_period_path(@period), alert: "#{blocking.size} #{'thing'.pluralize(blocking.size)} to fix first. Fix them, or lock anyway with a reason."
      end
      if blocking.any? && params[:reason].to_s.strip.blank?
        return redirect_to people_pay_period_path(@period), alert: 'Say why you are locking with open items.'
      end

      @period.lock!(by: Current.user, totals: summary.to_h, note: params[:reason].to_s.strip.presence)
      ActivityLogger.log('pay_period_locked', subject: @period, details: "#{@period.label}#{" · #{params[:reason]}" if params[:reason].present?}")
      redirect_to people_pay_period_path(@period), notice: "#{@period.label} locked. Hours, tips and time off inside it can no longer change."
    rescue ArgumentError => e
      redirect_to people_pay_period_path(@period), alert: e.message
    end

    def reopen
      authorize(:module, :payroll_write?)
      reason = params[:reason].to_s.strip
      return redirect_to people_pay_period_path(@period), alert: 'Say why the period is being reopened.' if reason.blank?
      return redirect_to people_pay_period_path(@period), alert: 'This period is already open.' if @period.open?

      @period.reopen!
      @period.update!(note: [@period.note, "Reopened #{Time.current.strftime('%b %-d, %Y')} by #{Current.user.display_name}: #{reason}"].compact.join("\n"))
      ActivityLogger.log('pay_period_reopened', subject: @period, details: "#{@period.label} · #{reason}#{" · earlier export sha256 #{@period.export_sha256}" if @period.export_sha256}")
      redirect_to people_pay_period_path(@period), notice: "#{@period.label} reopened. The earlier export's digest stays on record."
    end

    def add_adjustment
      authorize(:module, :payroll_write?)
      adjustment = @period.adjustments.build(adjustment_params.merge(created_by: Current.user))
      adjustment.amount_cents = (adjustment_params[:amount].to_d * 100).round if adjustment_params[:amount].present? && !adjustment.hours_kind?
      if adjustment.save
        ActivityLogger.log('pay_period_adjustment_added', subject: @period, details: "#{adjustment.employee.name} · #{adjustment.kind_label} #{adjustment.label} · #{adjustment.note}")
        redirect_to people_pay_period_path(@period, anchor: 'adjustments'), notice: 'Adjustment recorded for this period.'
      else
        redirect_to people_pay_period_path(@period, anchor: 'adjustments'), alert: adjustment.errors.full_messages.to_sentence
      end
    end

    private

    def set_period
      @period = PayPeriod.find(params[:id])
    end

    def adjustment_params
      params.fetch(:adjustment, {}).permit(:employee_id, :kind, :hours, :amount, :note)
    end

    def prevent_caching
      response.headers['Cache-Control'] = 'no-store'
    end
  end
end
