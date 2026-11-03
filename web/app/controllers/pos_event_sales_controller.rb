# frozen_string_literal: true

# Recording event-register sales (idempotent by client_sale_id) and showing a
# printable receipt with the COA QR codes.
class PosEventSalesController < AuthenticatedController
  include ComplianceAccess

  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can_use_pos?

    skip_authorization # gate: can_use_pos?; the recorder also requires the event's staff list
    response.headers['Cache-Control'] = 'no-store'
    @event = PosEvent.find(params[:pos_event_id])
  end

  # Later handlers win: Blocked (a Pos::Error) carries the issue list.
  rescue_from Pos::Error do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end
  rescue_from Compliance::Blocked do |error|
    render json: error.payload, status: :unprocessable_entity
  end

  def create
    sale = Pos::EventSaleRecorder.record!(event: @event, user: Current.user, params: params)
    render json: sale.receipt
  end

  def receipt
    @sale = @event.pos_event_sales.find(params[:id])
    raise Pundit::NotAuthorizedError unless @sale.user_id == Current.user.id || pos_event_manager?

    render layout: 'pos'
  end
end
