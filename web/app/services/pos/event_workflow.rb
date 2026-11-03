# frozen_string_literal: true

module Pos
  # Opening, pulling items from and closing an event (F70 event mode). Each step
  # is one transaction with its compliance audit row.
  module EventWorkflow
    module_function

    # Opens a draft after the pre-event checklist. Every item must still be on
    # the approved catalog and sellable for cash; the list, prices and card
    # eligibility are then frozen for the register.
    def open!(event, user:, checklist:)
      PosEvent.transaction do
        event.lock!
        raise Error, 'Only a draft event can be opened.' unless event.draft?

        ticked = PosEvent::CHECKLIST.keys.index_with { |key| ActiveModel::Type::Boolean.new.cast(checklist&.dig(key)) == true }
        missing = PosEvent::CHECKLIST.reject { |key, _| ticked[key] }.values
        raise Error, "Finish the pre-event checklist: #{missing.join('; ')}." if missing.any?
        raise Error, 'Add at least one approved item before opening.' if event.pos_event_items.empty?
        raise Error, 'Add the staff who will sell at this event.' if event.staff_user_ids.empty?

        policy = CompliancePolicy.for_event(event.location)
        items = event.pos_event_items.includes(compliance_catalog_item: %i[compliance_category certificates_of_analysis]).to_a
        lines = items.map { |item| Compliance::ItemEligibility::Line.new(key: item.id.to_s, name: item.name, catalog_item: item.compliance_catalog_item) }
        refused = Compliance::ItemEligibility.check(lines, tender: 'cash', policy: policy, on: [event.starts_on, Date.current].max).blocking
        raise Error, "Remove or fix before opening: #{refused.map(&:message).join(' ')}" if refused.any?

        items.each { |item| item.freeze_from_catalog!(on: Date.current, max_age_days: policy.coa_max_age_days) }
        event.update!(status: 'open', checklist_json: ticked, opened_by: user, opened_at: Time.current)
        ComplianceEvent.record!('event_opened', subject: event, pos_event_id: event.id,
          details: { 'items' => items.size, 'card_items' => items.count(&:card_eligible), 'staff' => event.staff_user_ids.size,
                     'opening_float_cents' => event.opening_float_cents })
      end
      event
    end

    def pull!(event, item, user:, reason:)
      reason = reason.to_s.squish
      raise Error, 'Say why the item is pulled (at least 8 characters).' if reason.length < 8

      PosEvent.transaction do
        event.lock!
        raise Error, 'Items can be pulled only while the event is open.' unless event.open?
        raise Error, 'That item was already pulled.' if item.reload.pulled?

        item.update!(pulled_at: Time.current, pulled_by_id: user.id)
        ComplianceEvent.record!('event_item_pulled', subject: event, pos_event_id: event.id, reason: reason,
          details: { 'event_item_id' => item.id, 'name' => item.name })
      end
    end

    # counted: { event_item_id => remaining units } (blank = not counted).
    def close!(event, user:, counted_cash_cents:, terminal_card_total_cents:, counted:, notes:)
      PosEvent.transaction do
        event.lock!
        raise Error, 'Only an open event can be closed.' unless event.open?

        event.pos_event_items.each do |item|
          value = counted&.dig(item.id.to_s).to_s.strip
          next if value.empty?
          raise Error, "Enter whole units counted for #{item.name}." unless value.match?(/\A\d{1,6}\z/)

          item.update!(counted_remaining: value.to_i)
        end
        event.update!(status: 'closed', counted_cash_cents: counted_cash_cents, terminal_card_total_cents: terminal_card_total_cents,
          close_notes: notes.to_s.strip.first(2000).presence, closed_by: user, closed_at: Time.current)
        summary = event.sales_summary
        ComplianceEvent.record!('event_closed', subject: event, pos_event_id: event.id,
          details: { 'sales' => summary[:count], 'total_cents' => summary[:total_cents], 'cash_variance_cents' => event.cash_variance_cents,
                     'card_variance_cents' => event.card_variance_cents, 'overrides' => summary[:overrides], 'flagged' => summary[:flagged] })
      end
      event
    end
  end
end
