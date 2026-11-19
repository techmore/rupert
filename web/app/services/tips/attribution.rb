# frozen_string_literal: true

module Tips
  # Turns one tip source into TipAllocation rows (docs/time-and-pay/DECISIONS.md).
  #
  #   Tips::Attribution.call(dejavoo_feed_event)        terminal sale / return / void / tip adjust
  #   Tips::Attribution.call(authorize_net_transaction) gateway transaction (only when no FEED event covers it)
  #   Tips::Attribution.call(order)                     a Rupert POS cash sale with a cash tip
  #
  # Idempotent: a source that already has counted rows is left alone unless `force: true`, which
  # reverses the old rows and writes a fresh split (after a punch correction, for example).
  # Never calls a gateway; it only reads what webhooks and imports stored.
  class Attribution
    SALE = /SALE|AUTH|CAPTURE|TICKET/i
    RETURN = /RETURN|REFUND|CREDIT/i
    VOID = /VOID|REVERS/i
    TIP_ADJUST = /TIP/i
    FAILED_STATUSES = %w[declined expired generalError failedReview].freeze

    def self.call(source, force: false)
      new(source, force: force).call
    end

    def initialize(source, force: false)
      @source = source
      @force = force
    end

    def call
      case @source
      when DejavooFeedEvent then feed_event(@source)
      when AuthorizeNetTransaction then authorize_net(@source)
      when Core::Order then order(@source)
      else raise ArgumentError, "Cannot attribute tips from #{@source.class}"
      end
    end

    # ---- Dejavoo FEED -----------------------------------------------------------------------

    def feed_event(event)
      return [] unless event.event_type == 'Transaction'
      return [] if event.host_response_code.present? && event.host_response_code != '00'

      kind = event.sub_event_type.to_s
      result = if kind.match?(VOID) then reverse_original(event, reason: 'Voided on the terminal', full: true)
      elsif kind.match?(RETURN) then reverse_original(event, reason: 'Refunded on the terminal', full: event.amount_cents.to_i >= original_amount(event))
      elsif kind.match?(TIP_ADJUST) && !kind.match?(SALE) then adjust_tip(event)
      else allocate_sale(event)
               end
      event.update_columns(tip_attributed_at: Time.current, updated_at: Time.current)
      result
    end

    def allocate_sale(event)
      existing = TipAllocation.live.where(source_kind: 'dejavoo_feed_event', source_id: event.id)
      if existing.exists?
        return existing.to_a unless @force

        existing.each { |row| row.reverse!(reason: 'Re-attributed', created_by: nil) }
      end
      return [] if event.tip_cents.to_i <= 0

      context = feed_context(event)
      write(Split.new(gross_cents: event.tip_cents, at: context[:at], location_id: context[:location_id], cashier: context[:cashier], evidence: context[:evidence]).rows,
        source_kind: 'dejavoo_feed_event', source_id: event.id, source_ref: event.transaction_id, status: 'estimated')
    end

    # Who ran the sale and where. Evidence: the checkout Rupert sent (cashier + store), else the clerk
    # number typed on the terminal, else the terminal's store and the people clocked in then.
    def feed_context(event)
      location_id = event.pos_setting&.location_id
      at = event.received_at
      cashier = nil
      evidence = 'time_register'
      checkout = feed_checkout(event)
      if checkout
        at = checkout.paid_at || at
        location_id = checkout.location_id
        cashier = employee_for_user(checkout.user_id)
        evidence = 'checkout' if cashier
      end
      if cashier.nil? && event.performed_by.present? && (clerk = People::Employee.find_by(employee_number: event.performed_by.to_s.strip))
        cashier = clerk
        evidence = 'clerk'
      end
      { at: at, location_id: location_id, cashier: cashier, evidence: evidence }
    end

    def feed_checkout(event)
      return PosPaymentAttempt.find_by(id: event.matched_id)&.pos_checkout if event.matched_kind == 'pos_payment_attempt'

      reference = [event.external_reference_id, event.invoice_number].compact_blank
      return nil if reference.empty?

      PosPaymentAttempt.where(invoice: reference).first&.pos_checkout || PosCheckout.find_by(reference: reference)
    end

    def original_event(event)
      scope = DejavooFeedEvent.where(pos_setting_id: event.pos_setting_id, event_type: 'Transaction').where.not(id: event.id)
      original = scope.find_by(rrn: event.original_rrn) if event.original_rrn.present?
      if original.nil? && event.external_reference_id.present? && event.external_reference_id != '0'
        original = scope.where(sub_event_type: 'SALE').find_by(external_reference_id: event.external_reference_id)
      end
      original ||= scope.where(sub_event_type: 'SALE').find_by(transaction_id: event.transaction_id) if event.transaction_id.present?
      original
    end

    def original_amount(event)
      original_event(event)&.amount_cents.to_i
    end

    # A void or refund undoes the original sale's tip rows (all of them, or the refunded share).
    def reverse_original(event, reason:, full:)
      original = original_event(event)
      rows = original ? TipAllocation.live.where(source_kind: 'dejavoo_feed_event', source_id: original.id).to_a : []
      rows = rows.reject { |r| TipAllocation.exists?(reverses_id: r.id) }
      return [] if rows.empty?
      return rows.map { |row| row.reverse!(reason: reason, created_by: nil, occurred_at: event.received_at) } if full

      fraction = original.amount_cents.to_i.positive? ? Rational(event.amount_cents.to_i, original.amount_cents.to_i) : 1r
      rows.filter_map do |row|
        delta = -(row.amount_cents * fraction).round
        next nil if delta.zero?

        TipAllocation.create!(row.attributes.slice('employee_id', 'clock_shift_id', 'location_id', 'tip_method', 'gross_tip_cents', 'share_count', 'evidence')
          .merge(source_kind: 'dejavoo_feed_event', source_id: event.id, source_ref: event.transaction_id, status: 'settled', amount_cents: delta,
            occurred_at: event.received_at, business_date: TipAllocation.business_date_for(event.received_at, location_id: row.location_id),
            note: "#{reason} (partial)", reverses: row))
      end
    end

    # The terminal changed the tip after the sale: write the difference with the original split.
    def adjust_tip(event)
      original = original_event(event)
      return allocate_sale(event) unless original

      allocated = TipAllocation.where(source_kind: 'dejavoo_feed_event', source_id: [original.id, event.id]).sum(:amount_cents)
      delta = event.tip_cents.to_i - allocated
      return [] if delta.zero?

      context = feed_context(original)
      write(Split.new(gross_cents: delta, at: context[:at], location_id: context[:location_id], cashier: context[:cashier], evidence: context[:evidence]).rows,
        source_kind: 'dejavoo_feed_event', source_id: event.id, source_ref: event.transaction_id, status: 'estimated', note: 'Tip adjusted on the terminal')
    end

    # ---- Authorize.net -----------------------------------------------------------------------

    # Only when no FEED event already covers this sale (same invoice / checkout reference): the
    # settlement then updates those rows instead (Tips::Reconciliation).
    def authorize_net(txn)
      existing = TipAllocation.live.where(source_kind: 'authorize_net_transaction', source_id: txn.id)
      if existing.exists?
        return existing.to_a unless @force

        existing.each { |row| row.reverse!(reason: 'Re-attributed', created_by: nil) }
      end
      type = txn.transaction_type.to_s
      return reverse_authorize_net(txn) if type.match?(RETURN) || type.match?(VOID) || %w[voided refundSettledSuccessfully].include?(txn.payment_status)
      return [] if feed_event_for(txn)
      return [] unless (txn.tip_amount || 0).positive? && FAILED_STATUSES.exclude?(txn.payment_status)

      checkout = authorize_net_checkout(txn)
      cashier = checkout && employee_for_user(checkout.user_id)
      settled = settled?(txn)
      rows = write(Split.new(gross_cents: (txn.tip_amount * 100).to_i, at: checkout&.paid_at || txn.submitted_at, location_id: checkout&.location_id,
        cashier: cashier, evidence: cashier ? 'checkout' : 'time_register').rows,
        source_kind: 'authorize_net_transaction', source_id: txn.id, source_ref: txn.source_transaction_id,
        status: settled ? 'settled' : 'estimated', settlement_ref: settled ? "anet:#{txn.source_batch_id.presence || txn.source_transaction_id}" : nil,
        settled_at: settled ? txn.settled_at || Time.current : nil)
      txn.update_columns(tip_attributed_at: Time.current, updated_at: Time.current)
      rows
    end

    def settled?(txn)
      txn.settlement_state.to_s.match?(/settled/i) || txn.payment_status == 'settledSuccessfully'
    end

    def reverse_authorize_net(txn)
      reference = txn.reference_transaction_id.presence
      rows = reference ? TipAllocation.live.where(source_ref: reference).to_a : []
      if rows.empty? && (feed = feed_event_for(txn))
        rows = TipAllocation.live.where(source_kind: 'dejavoo_feed_event', source_id: feed.id).to_a
      end
      txn.update_columns(tip_attributed_at: Time.current, updated_at: Time.current)
      rows.reject { |r| TipAllocation.exists?(reverses_id: r.id) }.map do |row|
        row.reverse!(reason: txn.transaction_type.to_s.match?(VOID) || txn.payment_status == 'voided' ? 'Voided at the gateway' : 'Refunded at the gateway',
          created_by: nil, occurred_at: txn.submitted_at)
      end
    end

    def authorize_net_checkout(txn)
      invoice = txn.invoice_number.to_s
      return nil if invoice.blank?

      PosCheckout.find_by(reference: invoice) || PosPaymentAttempt.find_by(invoice: invoice)&.pos_checkout
    end

    # The FEED event for the same sale: both carry the checkout reference as the invoice.
    def feed_event_for(txn)
      invoice = txn.invoice_number.to_s
      return nil if invoice.blank?

      DejavooFeedEvent.where(event_type: 'Transaction').where('external_reference_id = ? OR invoice_number = ?', invoice, invoice).order(:received_at).first
    end

    # ---- Rupert POS cash sales ---------------------------------------------------------------

    def order(order)
      existing = TipAllocation.live.where(source_kind: 'order', source_id: order.id)
      if existing.exists?
        return existing.to_a unless @force

        existing.each { |row| row.reverse!(reason: 'Re-attributed', created_by: nil) }
      end
      return [] unless order.source == 'rupert_pos' && order.tip_cents.to_i.positive?

      checkout = PosCheckout.find_by(order_id: order.id)
      # Card sales on the terminal or the gateway are covered by FEED / Authorize.net rows.
      return [] if checkout && checkout.tender == 'card' && %w[dejavoo_spin authorize_net].include?(checkout.gateway_provider)

      cashier = checkout && employee_for_user(checkout.user_id)
      cash = checkout.nil? || checkout.tender == 'cash'
      rows = Split.new(gross_cents: order.tip_cents, at: checkout&.paid_at || order.occurred_at, location_id: checkout&.location_id || order.location_id,
        cashier: cashier, evidence: cashier ? 'checkout' : 'time_register').rows
      rows.each { |r| r[:tip_method] = 'cash' if cash && r[:employee_id] }
      write(rows, source_kind: 'order', source_id: order.id, source_ref: order.source_order_id, status: cash ? 'settled' : 'estimated')
    end

    private

    def employee_for_user(user_id)
      return nil if user_id.blank?

      People::Employee.where(user_id: user_id).order(Arel.sql("CASE status WHEN 'active' THEN 0 ELSE 1 END")).first
    end

    def write(rows, **common)
      TipAllocation.transaction { rows.map { |attrs| TipAllocation.create!(attrs.merge(common)) } }
    end
  end
end
