# frozen_string_literal: true

module Sales
  # POS cash-drawer management: open a register shift, see sales per tender,
  # and settle with a physical cash count at end of day.
  class PosSessionsController < AuthenticatedController
    before_action :set_session, only: [:show, :close, :reopen, :refresh]

    def index
      authorize(:module, :sales_read?)
      @q = Sales::PosSession.ransack(params[:q])
      @pagy, @sessions = pagy(@q.result.order(opened_at: :desc), items: 20)
      @open_sessions = Sales::PosSession.where(status: "open").order(opened_at: :asc)
    end

    def show
      authorize(@session)
      @orders = Core::Order.where("occurred_at >= ?", @session.opened_at)
        .where(location_id: @session.location_id)
        .order(occurred_at: :desc).limit(100)
    end

    def new
      authorize(:module, :sales_write?)
      @session = Sales::PosSession.new(opened_at: Time.current, location_id: params[:location_id])
    end

    def create
      authorize(:module, :sales_write?)
      @session = Sales::PosSession.new(pos_session_params)
      @session.user_id = Current.user.id
      @session.opened_at = Time.current

      if @session.save
        redirect_to(@session, notice: "Register opened.")
      else
        render(:new, status: :unprocessable_entity)
      end
    end

    def refresh
      authorize(@session)
      @session.refresh_from_orders!
      DataCache.bump!
      redirect_to(@session, notice: "Tender totals refreshed from orders.")
    end

    def close
      authorize(@session)
      counted = params[:counted_cents].to_i
      @session.settle!(counted_cents: counted, notes: params[:notes])
      DataCache.bump!
      redirect_to(@session, notice: "Register settled and closed.")
    end

    def reopen
      authorize(@session)
      @session.reopen!
      redirect_to(@session, notice: "Register reopened.")
    end

    private

    def set_session
      @session = Sales::PosSession.find(params[:id])
    end

    def pos_session_params
      params.require(:pos_session).permit(:name, :location_id, :opening_cash_cents)
    end
  end
end
