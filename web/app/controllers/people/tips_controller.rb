# frozen_string_literal: true

module People
  # Tips for one pay period: who earned what (card from the terminal and gateway, cash declared),
  # what is settled money versus the terminal's estimate, tips nobody eligible was there for, and
  # how the ledger matches the gateway's settled batches. Managers assign unassigned tips here.
  class TipsController < AuthenticatedController
    before_action :authorize_read
    before_action :load_period

    def index
      @report = Tips::ReconciliationReport.for(@starts_on, @ends_on)
      @employees = People::Employee.active.ordered
      @period = PayPeriod.find_by(starts_on: @starts_on)
      respond_to do |format|
        format.html
        format.csv { send_data @report.to_csv, filename: "tips-#{@starts_on}-#{@ends_on}.csv", type: 'text/csv' }
      end
    end

    # POST /people/tips/assign — move an unassigned tip to one person (an audited adjustment pair).
    def assign
      authorize(:module, :payroll_write?)
      allocation = TipAllocation.find(params[:allocation_id])
      employee = People::Employee.find(params[:employee_id])
      raise ActiveRecord::RecordNotFound unless allocation.unassigned? && allocation.amount_cents.positive? && allocation.status != 'reversed'

      TipAllocation.transaction do
        allocation.reverse!(reason: "Assigned to #{employee.name}", created_by: Current.user)
        TipAllocation.create!(employee: employee, location_id: allocation.location_id, source_kind: 'manual', source_id: allocation.id, source_ref: allocation.source_ref,
          tip_method: 'adjustment', status: allocation.final? ? 'settled' : 'estimated', amount_cents: allocation.amount_cents, gross_tip_cents: allocation.gross_tip_cents,
          share_count: 1, occurred_at: allocation.occurred_at, business_date: allocation.business_date, settlement_ref: allocation.settlement_ref,
          settled_at: allocation.settled_at, evidence: 'manager', note: "Assigned by #{Current.user.display_name}", created_by: Current.user)
      end
      ActivityLogger.log('tips.assigned', subject: employee, details: { allocation_id: allocation.id, amount_cents: allocation.amount_cents }.to_json)
      redirect_to people_tips_path(period: @starts_on.iso8601), notice: "#{helpers.number_to_currency(allocation.amount_cents / 100.0)} assigned to #{employee.name}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to people_tips_path(period: @starts_on.iso8601), alert: e.message
    end

    private

    def authorize_read
      authorize(:module, Current.user.can?('payroll.read') ? :payroll_read? : :hr_write?)
    end

    def load_period
      date = params[:period].present? ? Date.iso8601(params[:period].to_s) : Date.current
      @starts_on, @ends_on = PayRules.current.period_range(date)
    rescue Date::Error
      @starts_on, @ends_on = PayRules.current.period_range(Date.current)
    end
  end
end
