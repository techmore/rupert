# frozen_string_literal: true

module People
  # Managers see trades waiting for a decision and approve or deny them. The approvals inbox calls
  # the same workflow (`People::ShiftTradeWorkflow.review`).
  class ShiftTradesController < AuthenticatedController
    before_action -> { require_time_feature(:scheduling, :shift_trades) }
    before_action { authorize(:module, :schedule_read?) }
    before_action :set_trade, only: %i[show approve deny]
    rescue_from People::ShiftTradeWorkflow::Error, with: :refused

    def index
      scope = People::ShiftTrade.includes(:scheduled_shift, :counter_shift, :from_employee, :to_employee).recent
      @status = params[:status].presence || 'accepted'
      @trades = (@status == 'all' ? scope : scope.where(status: @status)).limit(200).to_a
      @pending_count = People::ShiftTrade.pending_review.count
    end

    def show; end

    def approve
      authorize(:module, :schedule_write?)
      People::ShiftTradeWorkflow.review(@trade, reviewer: Current.user, approve: true, note: params[:note].to_s.strip.presence)
      redirect_to people_shift_trades_path, notice: 'Trade approved. Both people have been told.'
    end

    def deny
      authorize(:module, :schedule_write?)
      People::ShiftTradeWorkflow.review(@trade, reviewer: Current.user, approve: false, note: params[:note].to_s.strip.presence)
      redirect_to people_shift_trades_path, notice: 'Trade denied. Both people have been told.'
    end

    private

    def set_trade
      @trade = People::ShiftTrade.includes(:scheduled_shift, :counter_shift, :from_employee, :to_employee).find(params[:id])
    end

    def refused(error)
      redirect_to people_shift_trade_path(@trade || params[:id]), alert: error.message
    end
  end
end
