# frozen_string_literal: true

# The approved items and preset prices of a draft event, and pulling an item
# from an open one.
class PosEventItemsController < AuthenticatedController
  include ComplianceAccess

  before_action do
    raise Pundit::NotAuthorizedError unless pos_event_manager?

    skip_authorization # gate: pos_event_manager? (sales.write or override approvers)
    @event = PosEvent.find(params[:pos_event_id])
  end

  def create
    return draft_only unless @event.draft?
    return redirect_to(pos_event_path(@event), alert: "An event holds at most #{PosEvent::MAX_ITEMS} items.") if @event.pos_event_items.count >= PosEvent::MAX_ITEMS

    catalog_item = Compliance::Catalog.approved_items(@event.location).find(params[:compliance_catalog_item_id])
    price = price_cents(params[:price]) || catalog_item.approved_price_cents
    item = @event.pos_event_items.new(compliance_catalog_item: catalog_item, name: catalog_item.receipt_label, category_name: catalog_item.category_name,
      price_cents: price, loaded_quantity: quantity(params[:loaded_quantity]), position: @event.pos_event_items.maximum(:position).to_i + 1)
    if item.save
      redirect_to pos_event_path(@event, anchor: 'event-items'), notice: "#{item.name} added."
    else
      redirect_to pos_event_path(@event, anchor: 'event-items'), alert: item.errors.full_messages.to_sentence.presence || 'Set a preset price first.'
    end
  end

  def update
    return draft_only unless @event.draft?

    item = @event.pos_event_items.find(params[:id])
    if item.update(price_cents: price_cents(params[:price]) || item.price_cents, loaded_quantity: quantity(params[:loaded_quantity]))
      redirect_to pos_event_path(@event, anchor: 'event-items'), notice: "#{item.name} saved."
    else
      redirect_to pos_event_path(@event, anchor: 'event-items'), alert: item.errors.full_messages.to_sentence
    end
  end

  def destroy
    return draft_only unless @event.draft?

    @event.pos_event_items.find(params[:id]).destroy!
    redirect_to pos_event_path(@event, anchor: 'event-items'), notice: 'Item removed from the event.'
  end

  def pull
    item = @event.pos_event_items.find(params[:id])
    Pos::EventWorkflow.pull!(@event, item, user: Current.user, reason: params[:reason])
    redirect_to pos_event_path(@event, anchor: 'event-items'), notice: "#{item.name} pulled. The register stops selling it on its next refresh."
  rescue Pos::Error => error
    redirect_to pos_event_path(@event, anchor: 'event-items'), alert: error.message
  end

  private

  def draft_only = redirect_to(pos_event_path(@event), alert: 'The item list is frozen once the event opens. Pull an item instead.')
  def price_cents(value) = value.to_s.strip.match?(/\A\d{1,6}(?:\.\d{1,2})?\z/) ? (BigDecimal(value.to_s.strip) * 100).to_i : nil
  def quantity(value) = value.to_s.strip.match?(/\A\d{1,5}\z/) ? value.to_i : nil
end
