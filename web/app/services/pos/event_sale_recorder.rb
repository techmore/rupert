# frozen_string_literal: true

module Pos
  # Records one event-register sale (F70 event mode).
  #
  # - Replay-safe: the device names each sale with a client_sale_id before it
  #   sends it; a repeat of that id returns the sale already recorded.
  # - Server-priced: only event item ids and whole quantities come from the
  #   device. Prices are the event's frozen preset prices; tax is the event rate.
  # - Checked: every line passes Compliance::SaleGate against the live approved
  #   catalog for the tender, with the 21+ ID confirmation, or carries a manager
  #   PIN override. Card means a card run on the event's own terminal; Rupert
  #   never charges a card here.
  # - Offline tolerant: a sale the device queued while offline was already paid.
  #   If the catalog changed before it synced (item suspended, COA lapsed) it is
  #   still recorded, flagged for review, rather than lost. A sale the frozen
  #   event list itself would refuse is never accepted, offline or not.
  class EventSaleRecorder
    MAX_LINES = 40
    MAX_QUANTITY = 99
    OFFLINE_GRACE = 72.hours

    def self.record!(event:, user:, params:) = new(event, user, params).record!

    def initialize(event, user, params)
      @event = event
      @user = user
      @params = params
    end

    def record!
      client_id = @params[:client_sale_id].to_s
      existing = @event.pos_event_sales.find_by(client_sale_id: client_id)
      return existing if existing

      raise Error, 'This event is not open for sales.' unless @event.open?
      raise Error, 'You are not on this event’s staff list.' unless @event.seller?(@user)

      tender = @params[:tender].to_s
      raise Error, 'Choose cash or card (terminal).' unless PosEventSale::TENDERS.include?(tender)

      offline = ActiveModel::Type::Boolean.new.cast(@params[:offline]) == true
      occurred_at = occurred_at(offline)
      lines = event_lines
      frozen_refusal!(lines, tender, offline, occurred_at)

      policy = CompliancePolicy.for_event(@event.location)
      eligibility = lines.map { |item, _| Compliance::ItemEligibility::Line.new(key: item.id.to_s, name: item.name, catalog_item: item.compliance_catalog_item) }
      result = Compliance::SaleGate.evaluate(eligibility, tender: tender, id_checked: id_checked?, policy: policy, on: occurred_at.to_date)
      flags = []
      approver = nil
      override = Compliance::SaleGate::Override.from(@params)
      if !result.allowed? && offline && override.nil? && result.blocking.none? { |issue| issue.code == :id_not_checked }
        flags = result.blocking.map { |issue| issue.code.to_s }.uniq
      else
        approver = Compliance::SaleGate.enforce!(result, override: override, location_id: @event.location_id, pos_event_id: @event.id,
          details: { 'source' => 'event', 'tender' => tender, 'client_sale_id' => client_id })
      end
      flags << 'pulled_item' if lines.any? { |item, _| item.pulled? }

      persist!(client_id, tender, lines, occurred_at, flags, approver, result)
    rescue ActiveRecord::RecordNotUnique
      @event.pos_event_sales.find_by!(client_sale_id: client_id)
    end

    private

    def id_checked? = ActiveModel::Type::Boolean.new.cast(@params[:id_checked]) == true

    def occurred_at(offline)
      return Time.current unless offline

      at = Time.iso8601(@params[:occurred_at].to_s)
      raise Error, 'An offline sale has an impossible time. Check the device clock.' if at > 5.minutes.from_now || at < (@event.opened_at || Time.current) - 5.minutes || at < OFFLINE_GRACE.ago
      at
    rescue ArgumentError
      raise Error, 'An offline sale is missing the time it happened.'
    end

    def event_lines
      rows = @params[:lines]
      rows = rows.values if rows.is_a?(ActionController::Parameters) && !rows.is_a?(Array)
      raise Error, "Add between 1 and #{MAX_LINES} items." unless rows.is_a?(Array) && rows.size.between?(1, MAX_LINES)

      items = @event.pos_event_items.includes(compliance_catalog_item: %i[compliance_category certificates_of_analysis]).index_by(&:id)
      lines = rows.map do |row|
        item = items[row[:event_item_id].to_i]
        raise Error, 'An item is not on this event’s list.' unless item
        raise Error, "Choose a whole quantity from 1 to #{MAX_QUANTITY}." unless row[:quantity].to_s.match?(/\A[1-9]\d?\z/)

        [item, row[:quantity].to_i]
      end
      raise Error, 'Each item can appear once; change its quantity instead.' unless lines.map { |item, _| item.id }.uniq.size == lines.size

      lines
    end

    # What the device itself was told when the event opened: these never sell.
    # An item pulled before the sale never sells; one pulled after an offline
    # sale happened is recorded and flagged.
    def frozen_refusal!(lines, tender, offline, occurred_at)
      pulled = lines.find { |item, _| item.pulled? && (!offline || item.pulled_at <= occurred_at) }
      raise Error, "#{pulled.first.name} was pulled from this event." if pulled
      return unless tender == 'card_terminal'

      cash_only = lines.find { |item, _| !item.card_eligible }
      return unless cash_only && Compliance::SaleGate::Override.from(@params).nil?

      # Logged like any blocked sale; a manager override then goes through SaleGate.
      Compliance::SaleGate.enforce!(card_result(cash_only.first), override: nil, location_id: @event.location_id, pos_event_id: @event.id,
        details: { 'source' => 'event', 'tender' => tender, 'client_sale_id' => @params[:client_sale_id].to_s })
    end

    def card_result(item)
      Compliance::ItemEligibility::Result.new([Compliance::ItemEligibility::Issue.new(code: :card_ineligible, severity: :block, overridable: true,
        item_key: item.id.to_s, item_name: item.name, message: "#{item.name} is cash only at this event.")], :card)
    end

    def persist!(client_id, tender, lines, occurred_at, flags, approver, result)
      sale_lines = lines.map do |item, quantity|
        line_cents = item.price_cents * quantity
        { 'event_item_id' => item.id, 'catalog_item_id' => item.compliance_catalog_item_id, 'name' => item.name, 'quantity' => quantity,
          'unit_cents' => item.price_cents, 'line_cents' => line_cents, 'tax_cents' => @event.tax_cents_for(line_cents), 'coa_url' => item.coa_url }
      end
      subtotal = sale_lines.sum { |line| line['line_cents'] }
      tax = sale_lines.sum { |line| line['tax_cents'] }
      total = subtotal + tax
      received = change = nil
      if tender == 'cash'
        received = Checkout.money(@params[:cash_received])
        raise Error, 'Cash received is less than the total.' if received < total

        change = received - total
      end

      PosEventSale.transaction do
        sale = @event.pos_event_sales.create!(user: @user, client_sale_id: client_id, tender: tender, lines_json: sale_lines,
          subtotal_cents: subtotal, tax_cents: tax, total_cents: total, cash_received_cents: received, change_cents: change,
          id_checked: id_checked?, override_by: approver, override_reason: approver && @params[:override_reason].to_s.squish,
          flags_json: flags.presence, occurred_at: occurred_at)
        sale.update!(order: canonical_order!(sale))
        details = { 'tender' => tender, 'total_cents' => total, 'units' => sale.units, 'warnings' => result.warnings.map { |w| w.code.to_s }.uniq }
        ComplianceEvent.record!('event_sale', subject: sale, location_id: @event.location_id, pos_event_id: @event.id, details: details)
        if flags.any?
          ComplianceEvent.record!('event_sale_flagged', subject: sale, location_id: @event.location_id, pos_event_id: @event.id,
            reason: 'Recorded from an offline queue after the approved catalog changed.', details: details.merge('flags' => flags))
        end
        sale
      end
    end

    def canonical_order!(sale)
      order = Core::Order.create!(source: 'rupert_pos', source_order_id: "event-#{@event.id}-#{sale.client_sale_id}", order_number: "EV-#{sale.id}",
        channel: 'pos', location_id: @event.location.externalId, currency: 'USD', occurred_at: sale.occurred_at,
        gross_cents: sale.total_cents, tax_cents: sale.tax_cents, tip_cents: 0, line_items: sale.units, source_lines_complete: true)
      sale.lines.each do |line|
        order.order_lines.create!(source_line_id: "event-item-#{line['event_item_id']}", sku: nil, name: line['name'], quantity: line['quantity'],
          unit_cents: line['unit_cents'], line_cents: line['line_cents'])
      end
      prefix = sale.tender == 'cash' ? 'event_cash' : 'event_terminal'
      order.payments.create!(method: sale.tender == 'cash' ? 'cash' : 'card', amount_cents: sale.total_cents, status: 'completed',
        paid_at: sale.occurred_at, reference: "#{prefix}-#{@event.id}-#{sale.client_sale_id}")
      order.mark_paid!
      order
    end
  end
end
