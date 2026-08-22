# frozen_string_literal: true

# Port of shopifyLedgerEntries/squareLedgerEntries/upsertLedger from the
# legacy console — mirrors order money data into the LedgerEntry table.
class LedgerImporter
  def self.from_shopify_orders!(nodes)
    entries = Array(nodes).map do |order|
      money = order.dig("currentTotalPriceSet", "shopMoney")
      items = order.dig("lineItems", "nodes") || []
      {
        id: "shopify:#{order["id"]}",
        source: "shopify",
        sourceOrderId: order["id"],
        orderName: order["name"] || order["id"],
        occurredAt: Time.zone.parse(order["createdAt"]),
        syncedAt: Time.current,
        currency: money&.dig("currencyCode") || "USD",
        grossCents: ((money&.dig("amount").to_f || 0) * 100).round,
        status: order["displayFinancialStatus"] || "ANY",
        lineItems: items.sum { |item| item["quantity"].to_i },
        summary: items.first(3).map { |item| item["title"] }.join(", "),
      }
    end
    upsert!(entries)
    CanonicalOrderImporter.from_shopify!(nodes)
  end

  def self.from_square_orders!(orders)
    entries = Array(orders).map do |order|
      amount = order.dig("total_money", "amount").to_i
      items = order["line_items"] || []
      {
        id: "square:#{order["id"]}",
        source: "square",
        sourceOrderId: order["id"],
        orderName: "SQ-#{order["id"].to_s.slice(0, 12)}",
        occurredAt: begin
          parsed = Time.zone.parse(order["created_at"])
          Rails.logger.warn("LedgerImporter: bad Square order created_at #{order['created_at'].inspect} for order #{order['id']}") if parsed.nil?
          parsed || Time.current
        rescue TypeError, ArgumentError => e
          Rails.logger.warn("LedgerImporter: could not parse Square order created_at #{order['created_at'].inspect}: #{e.message}")
          Time.current
        end,
        syncedAt: Time.current,
        currency: order.dig("total_money", "currency") || "USD",
        grossCents: amount,
        status: order["state"] || "UNKNOWN",
        lineItems: items.sum { |item| item["quantity"].to_i },
        summary: items.first(3).map { |item| item["name"] || item["catalog_object_name"] || "Item" }.join(", "),
      }
    end
    upsert!(entries)
    CanonicalOrderImporter.from_square!(orders)
  end

  def self.upsert!(entries)
    # Bulk writes skip callbacks, so rows carry tenant_id explicitly (this also
    # heals the historical NULL-tenant ledger rows on conflict).
    entries.each { |entry| entry[:tenant_id] = Current.tenant_id }
    LedgerEntry.upsert_all(entries, unique_by: :id) if entries.any?
    entries.length
  end
end
