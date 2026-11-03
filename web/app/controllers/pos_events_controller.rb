# frozen_string_literal: true

require 'csv'

# Sell → Events (F70 event mode): set up a show or pop-up from the approved
# catalog, open it after the pre-event checklist, watch it and close it with
# the cash count, terminal batch total and counted stock.
class PosEventsController < AuthenticatedController
  include ComplianceAccess

  before_action :require_viewer
  before_action :require_manager, except: %i[index show]
  before_action :load_event, except: %i[index new create]

  def index
    @events = PosEvent.includes(:location).recent.to_a
  end

  def show
    @summary = @event.sales_summary
    @units_sold = @event.units_sold
    @sales = @event.pos_event_sales.includes(:user, :override_by).order(occurred_at: :desc).to_a
    @audit = ComplianceEvent.where(pos_event_id: @event.id).recent.limit(100).to_a
    @catalog_items = addable_items if @event.draft?
    respond_to do |format|
      format.html
      format.csv do
        log_export('Event sales CSV', @event.name)
        send_data sales_csv, filename: "event-#{@event.id}-sales.csv", type: 'text/csv'
      end
    end
  end

  def new
    @event = PosEvent.new(starts_on: Date.current, ends_on: Date.current, location: default_location, staff_user_ids_json: [Current.user.id])
  end

  def create
    @event = PosEvent.new(event_params.merge(created_by: Current.user, status: 'draft'))
    saved = PosEvent.transaction do
      next false unless @event.save

      ComplianceEvent.record!('event_created', subject: @event, pos_event_id: @event.id)
      true
    end
    return render(:new, status: :unprocessable_entity) unless saved

    redirect_to pos_event_path(@event), notice: 'Event added. Add its approved items and preset prices next.'
  end

  def edit
    redirect_to(pos_event_path(@event), alert: 'Only a draft event can be edited.') unless @event.draft?
  end

  def update
    return redirect_to(pos_event_path(@event), alert: 'Only a draft event can be edited.') unless @event.draft?

    saved = PosEvent.transaction do
      next false unless @event.update(event_params.except(:location_id))

      ComplianceEvent.record!('event_edited', subject: @event, pos_event_id: @event.id)
      true
    end
    return render(:edit, status: :unprocessable_entity) unless saved

    redirect_to pos_event_path(@event), notice: 'Event saved.'
  rescue ActiveRecord::StaleObjectError
    redirect_to edit_pos_event_path(@event), alert: 'Someone else changed this event. Review it and save again.'
  end

  def open
    Pos::EventWorkflow.open!(@event, user: Current.user, checklist: params[:checklist])
    redirect_to pos_event_path(@event), notice: 'Event open. Staff can sell from the event register.'
  rescue Pos::Error => error
    redirect_to pos_event_path(@event), alert: error.message
  end

  def close
    cash = Pos::Checkout.money(params[:counted_cash])
    card = params[:terminal_card_total].to_s.strip.empty? ? nil : Pos::Checkout.money(params[:terminal_card_total])
    Pos::EventWorkflow.close!(@event, user: Current.user, counted_cash_cents: cash, terminal_card_total_cents: card,
      counted: params[:counted]&.to_unsafe_h, notes: params[:close_notes])
    redirect_to pos_event_path(@event), notice: 'Event closed. The reconciliation is below.'
  rescue Pos::Error => error
    redirect_to pos_event_path(@event), alert: error.message
  end

  private

  def require_viewer
    raise Pundit::NotAuthorizedError unless compliance_viewer? || pos_event_manager?

    skip_authorization # gate: compliance_viewer? or pos_event_manager?
  end

  def require_manager
    raise Pundit::NotAuthorizedError unless pos_event_manager?
  end

  def load_event
    @event = PosEvent.includes(:location, pos_event_items: { compliance_catalog_item: %i[compliance_category certificates_of_analysis] }).find(params[:id])
    @policy = CompliancePolicy.for_event(@event.location)
  end

  def default_location
    ComplianceCatalogItem.approved.order(:location_id).first&.location || CtraxStockSnapshot.order(:location_id).first&.location
  end

  def addable_items
    taken = @event.pos_event_items.map(&:compliance_catalog_item_id)
    Compliance::Catalog.approved_items(@event.location).ordered.reject { |item| taken.include?(item.id) || item.compliance_category.prohibited }
  end

  def event_params
    permitted = params.require(:pos_event).permit(:name, :venue, :location_id, :starts_on, :ends_on, :tax_rate, :opening_float, :lock_version, staff_user_ids: [])
    rate = permitted.delete(:tax_rate).to_s.strip
    permitted[:tax_rate_bps] = rate.match?(/\A\d{1,2}(?:\.\d{1,2})?\z/) ? (BigDecimal(rate) * 100).to_i : 0
    float = permitted.delete(:opening_float).to_s.strip
    permitted[:opening_float_cents] = float.match?(/\A\d{1,6}(?:\.\d{1,2})?\z/) ? (BigDecimal(float) * 100).to_i : 0
    if permitted.key?(:staff_user_ids)
      ids = Array(permitted.delete(:staff_user_ids)).reject(&:blank?).map(&:to_i)
      permitted[:staff_user_ids_json] = User.where(tenant_id: Current.tenant_id, id: ids).active.pluck(:id)
    end
    permitted.delete(:location_id) unless permitted[:location_id].blank? || Location.exists?(id: permitted[:location_id])
    permitted
  end

  def sales_csv
    CSV.generate do |csv|
      csv << %w[sale_id occurred_at staff tender item quantity unit_cents line_cents line_tax_cents sale_total_cents id_checked override_by override_reason flags order_number]
      @sales.reverse_each do |sale|
        sale.lines.each do |line|
          csv << [sale.id, sale.occurred_at.iso8601, sale.user.display_name || sale.user.email, sale.tender, line['name'], line['quantity'],
            line['unit_cents'], line['line_cents'], line['tax_cents'], sale.total_cents, sale.id_checked, sale.override_by&.display_name,
            sale.override_reason, sale.flags.join(' '), sale.order&.order_number]
        end
      end
    end
  end
end
