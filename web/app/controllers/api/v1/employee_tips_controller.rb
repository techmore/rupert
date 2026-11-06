# frozen_string_literal: true

module Api
  module V1
    # The staff app's pay summary and cash tip declarations. Own records only.
    class EmployeeTipsController < EmployeeBaseController
      rescue_from Tips::Declare::Error, with: :invalid

      # GET /api/v1/employee/pay?period=YYYY-MM-DD
      def show
        date = params[:period].present? ? Date.iso8601(params[:period].to_s) : Date.current
        pay = EmployeePayWeek.new(employee: worker, week_of: date)
        period = PayPeriod.find_by(starts_on: pay.start_date)
        render json: { data: {
          period_start: pay.start_date, period_end: pay.end_date, final: period&.locked? || false,
          next_payday: pay.end_date + TimeRules.for(worker.location_ids.first).payday_days_after_period_end,
          paid_hours: pay.paid_hours.round(2), hourly_rate_cents: pay.hourly_rate_cents, base_cents: pay.base_cents,
          commission_cents: pay.commission_cents, tip_cents: pay.tip_cents, card_tip_cents: pay.card_tip_cents, cash_tip_cents: pay.cash_tip_cents,
          estimated_tip_cents: pay.estimated_tip_cents, final_tip_cents: pay.final_tip_cents, total_cents: pay.base_cents && pay.total_cents,
          tips: pay.tip_allocations.map { |a| a.as_json(only: %i[id occurred_at business_date tip_method status amount_cents gross_tip_cents share_count note]) }
        } }
      rescue Date::Error
        render json: { error: 'invalid_request', message: 'period must be a date' }, status: :unprocessable_entity
      end

      # POST /api/v1/employee/tips {cash_tips:{amount_cents, shift_id|on}}
      def create
        values = params.require(:cash_tips).permit(:amount_cents, :shift_id, :on)
        row = Tips::Declare.call(worker: worker, amount_cents: values[:amount_cents], shift: values[:shift_id].presence, on: values[:on].presence)
        render json: { data: row&.as_json(only: %i[id occurred_at business_date tip_method status amount_cents]) }, status: :created
      end
    end
  end
end
