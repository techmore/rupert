# frozen_string_literal: true

module Api
  module V1
    # Offer, accept and cancel shift trades from the staff app (same workflow as the web pages).
    class EmployeeTradesController < EmployeeBaseController
      before_action -> { require_time_feature(:scheduling, :shift_trades) }
      rescue_from People::ShiftTradeWorkflow::Error, with: :invalid

      # POST { kind: give|swap|pickup, shift_id, counter_shift_id?, note? }
      def create
        shift = People::ScheduledShift.live.published.find(params[:shift_id])
        counter = params[:counter_shift_id].present? ? People::ScheduledShift.live.published.find(params[:counter_shift_id]) : nil
        trade = People::ShiftTradeWorkflow.offer(shift, kind: params[:kind].to_s, by: Current.user, counter_shift: counter, note: params[:note].to_s.strip.presence)
        render json: { data: trade_json(trade) }, status: :created
      end

      def accept
        trade = People::ShiftTradeWorkflow.accept(People::ShiftTrade.find(params[:id]), by: Current.user)
        render json: { data: trade_json(trade.reload) }
      end

      def cancel
        trade = People::ShiftTradeWorkflow.cancel(People::ShiftTrade.find(params[:id]), by: Current.user)
        render json: { data: trade_json(trade) }
      end

      private

      def trade_json(trade)
        { id: trade.id, kind: trade.kind, status: trade.status, shift_id: trade.scheduled_shift_id, counter_shift_id: trade.counter_shift_id,
          from_employee_id: trade.from_employee_id, to_employee_id: trade.to_employee_id, note: trade.note, review_note: trade.review_note,
          checks: trade.checks }
      end
    end
  end
end
