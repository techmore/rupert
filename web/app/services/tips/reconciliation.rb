# frozen_string_literal: true

module Tips
  # Matches estimated tip allocations to settled money and keeps the ledger honest:
  #
  # - a Dejavoo FEED settlement (batch close) settles every allocation of that batch's sales;
  # - a settled Authorize.net transaction settles the FEED rows for the same sale, writes a delta
  #   when the settled tip differs from the terminal's figure, or attributes the tip itself when
  #   no FEED event covered the sale;
  # - refunds and voids reverse the rows they undo (negative mirrored rows, never edits).
  #
  # Runs hourly (Tips::ReconcileJob) and right after webhooks/imports. Reads only; never calls a gateway.
  class Reconciliation
    LOOKBACK = 45.days

    def run
      DejavooFeedEvent.where(event_type: 'Settlement', tip_attributed_at: nil).find_each { |event| settle_dejavoo_batch(event) }
      DejavooFeedEvent.where(event_type: 'Transaction', tip_attributed_at: nil).find_each { |event| Attribution.call(event) }
      AuthorizeNetTransaction.where('observed_at > ?', LOOKBACK.ago).find_each { |txn| authorize_net_transaction(txn) }
      attribute_cash_orders
      self
    end

    # A closed terminal batch: everything estimated for sales in that batch is now settled money.
    def settle_dejavoo_batch(event)
      batch = event.batch_number.presence
      if batch
        sales = DejavooFeedEvent.where(pos_setting_id: event.pos_setting_id, event_type: 'Transaction', batch_number: batch).select(:id)
        TipAllocation.where(source_kind: 'dejavoo_feed_event', source_id: sales, status: %w[estimated carried])
          .update_all(status: 'settled', settlement_ref: "dejavoo-batch:#{batch}", settled_at: event.received_at, updated_at: Time.current)
      end
      event.update_columns(tip_attributed_at: Time.current, updated_at: Time.current)
    end

    def authorize_net_transaction(txn)
      attribution = Attribution.new(txn)
      type = txn.transaction_type.to_s
      reversal = type.match?(Attribution::RETURN) || type.match?(Attribution::VOID) || %w[voided refundSettledSuccessfully].include?(txn.payment_status)
      return Attribution.call(txn) if reversal && txn.tip_attributed_at.nil?
      return [] if reversal

      feed = attribution.feed_event_for(txn)
      return attribute_or_settle_gateway_rows(txn) if feed.nil?
      return [] unless attribution.settled?(txn)

      settle_feed_rows(feed, txn)
    end

    # FEED rows for the same sale: settled now, plus a delta when the gateway settled a different tip.
    def settle_feed_rows(feed, txn)
      ref = "anet:#{txn.source_batch_id.presence || txn.source_transaction_id}"
      rows = TipAllocation.where(source_kind: 'dejavoo_feed_event', source_id: feed_family_ids(feed))
      rows.where(status: %w[estimated carried]).update_all(status: 'settled', settlement_ref: ref, settled_at: txn.settled_at || Time.current, updated_at: Time.current)
      settled_tip = txn.tip_amount.nil? ? nil : (txn.tip_amount * 100).to_i
      allocated = rows.sum(:amount_cents)
      delta = settled_tip.nil? ? 0 : settled_tip - allocated
      written = []
      if delta != 0 && TipAllocation.live.where(source_kind: 'authorize_net_transaction', source_id: txn.id).none?
        context = Attribution.new(feed).feed_context(feed)
        written = TipAllocation.transaction do
          Split.new(gross_cents: delta, at: context[:at], location_id: context[:location_id], cashier: context[:cashier], evidence: context[:evidence]).rows.map do |attrs|
            TipAllocation.create!(attrs.merge(source_kind: 'authorize_net_transaction', source_id: txn.id, source_ref: txn.source_transaction_id, status: 'settled',
              settlement_ref: ref, settled_at: txn.settled_at || Time.current, note: 'Tip adjusted at settlement'))
          end
        end
      end
      txn.update_columns(tip_attributed_at: Time.current, updated_at: Time.current)
      written
    end

    # Rows for a sale and for any tip adjustment that refers back to it.
    def feed_family_ids(feed)
      ids = [feed.id]
      ids += DejavooFeedEvent.where(pos_setting_id: feed.pos_setting_id, event_type: 'Transaction', original_rrn: feed.rrn).where.not(id: feed.id).pluck(:id) if feed.rrn.present?
      ids
    end

    def attribute_or_settle_gateway_rows(txn)
      existing = TipAllocation.live.where(source_kind: 'authorize_net_transaction', source_id: txn.id)
      return Attribution.call(txn) if existing.none?

      if Attribution.new(txn).settled?(txn)
        existing.where(status: %w[estimated carried]).update_all(status: 'settled', settlement_ref: "anet:#{txn.source_batch_id.presence || txn.source_transaction_id}",
          settled_at: txn.settled_at || Time.current, updated_at: Time.current)
      end
      existing.to_a
    end

    def attribute_cash_orders
      done = TipAllocation.where(source_kind: 'order').select(:source_id)
      Core::Order.where(source: 'rupert_pos').where('tip_cents > 0').where('occurred_at > ?', LOOKBACK.ago).where.not(id: done).find_each do |order|
        Attribution.call(order)
      end
    end
  end
end
