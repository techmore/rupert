# frozen_string_literal: true

# Maps the Shopify/Square ledger feeds into the canonical Core::Order stream.
# Idempotent: upserts on (tenant_id, source, source_order_id).
#
# Also provides a one-time backfill from the existing LedgerEntry mirror so the
# canonical order history starts populated.
class CanonicalOrderImporter
  class << self
    def from_shopify!(entries)
      entries.each do |entry|
        Core::Order.upsert(
          order_attrs(entry, channel: "online"),
          unique_by: [:tenant_id, :source, :source_order_id],
        )
      end
      entries.length
    end

    def from_square!(entries)
      entries.each do |entry|
        Core::Order.upsert(
          order_attrs(entry, channel: "pos"),
          unique_by: [:tenant_id, :source, :source_order_id],
        )
      end
      entries.length
    end

    # One-time: hydrate canonical orders from every ledger entry already mirrored.
    def backfill_from_ledger!
      count = 0
      LedgerEntry.find_in_batches do |batch|
        batch.each do |entry|
          next if entry.sourceOrderId.blank?

          Core::Order.upsert(
            order_attrs(
              source: entry.source,
              sourceOrderId: entry.sourceOrderId,
              occurredAt: entry.occurredAt,
              grossCents: entry.grossCents,
              status: entry.status,
              lineItems: entry.lineItems,
              orderName: entry.orderName,
            ),
            unique_by: [:tenant_id, :source, :source_order_id],
          )
          count += 1
        end
      end
      count
    end

    private

    def order_attrs(entry = nil, channel: nil, **kw)
      data = entry || kw
      {
        tenant_id: Current.tenant_id,
        source: data[:source] || data["source"],
        source_order_id: data[:sourceOrderId] || data["sourceOrderId"],
        order_number: data[:orderName] || data["orderName"],
        channel: channel || data[:channel] || data["channel"],
        occurred_at: data[:occurredAt] || data["occurredAt"],
        gross_cents: (data[:grossCents] || data["grossCents"]).to_i,
        status: normalize_status(data[:status] || data["status"]),
        line_items: (data[:lineItems] || data["lineItems"]).to_i,
        currency: data[:currency] || data["currency"] || "USD",
        created_at: Time.current,
        updated_at: Time.current,
      }
    end

    # Map display statuses from either platform into our aasm state names.
    def normalize_status(raw)
      case raw.to_s.upcase
      when "PAID", "COMPLETED", "CLOSED" then "paid"
      when "PARTIALLY_REFUNDED", "REFUNDED", "CANCELED", "CANCELLED" then "refunded"
      when "OPEN", "PLACED", "PARTIALLY_PAID" then "placed"
      when "ANY" then "placed"
      else "placed"
      end
    end
  end
end
