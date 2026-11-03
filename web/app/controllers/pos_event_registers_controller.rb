# frozen_string_literal: true

# The full-screen event register (F70 event mode): large tiles from the event's
# frozen item list, cash or card (terminal), ID check, and an offline queue.
class PosEventRegistersController < AuthenticatedController
  layout 'pos'

  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can_use_pos?

    skip_authorization # gate: can_use_pos?; selling also needs the event's staff list (PosEvent#seller?)
    response.headers['Cache-Control'] = 'no-store'
  end

  def show
    @event = PosEvent.includes(:location, :pos_event_items).find(params[:pos_event_id])
    @seller = @event.seller?(Current.user)
    @items = @event.sellable_items
    @approvers = Compliance::SaleGate.approvers
    respond_to do |format|
      format.html
      format.json { render json: register_state }
    end
  end

  private

  def register_state
    { event_id: @event.id, status: @event.status, seller: @seller, tax_rate_bps: @event.tax_rate_bps,
      items: @items.map(&:register_payload), pulled_item_ids: @event.pos_event_items.select(&:pulled?).map(&:id),
      approvers: @approvers.map { |user| { id: user.id, name: user.display_name || user.email } } }
  end
end
