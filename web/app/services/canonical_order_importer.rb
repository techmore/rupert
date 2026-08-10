# frozen_string_literal: true

# Maps the Shopify/Square raw payloads into the canonical Core::Order stream
# (orders + order_lines + payments + customers). Idempotent: upserts on
# (tenant_id, source, source_order_id) and replaces line items/payments per
# order on each sync so the canonical store stays in lock-step with the feeds.
#
# Also provides a one-time backfill from the existing LedgerEntry mirror for
# orders that predate the canonical store.
class CanonicalOrderImporter
  class << self
    def from_shopify!(nodes)
      Array(nodes).each do |node|
        next if node.blank?

        customer = upsert_customer!(
          source: "shopify",
          external_id: node.dig("customer", "id"),
          email: node.dig("customer", "email"),
          first_name: node.dig("customer", "firstName"),
          last_name: node.dig("customer", "lastName"),
          phone: node.dig("customer", "phone"),
        )

        Core::Order.upsert(
          order_attrs(node, source: "shopify", channel: "online", customer_id: customer&.id),
          unique_by: [:tenant_id, :source, :source_order_id],
        )
        order = Core::Order.find_by(
          tenant_id: Current.tenant_id,
          source: "shopify",
          source_order_id: node["id"],
        )
        replace_order_lines!(order, node["lineItems"])
        replace_payments!(order, shopify_payments(node))
        fulfillments = node["fulfillments"]
        fulfillments = fulfillments["nodes"] if fulfillments.is_a?(Hash)
        replace_fulfillments!(order, fulfillments)
      end
      Array(nodes).length
    end

    def from_square!(orders)
      Array(orders).each do |node|
        next if node.blank?

        customer = upsert_customer!(
          source: "square",
          external_id: node["customer_id"].presence || node["id"],
          email: nil,
          first_name: nil,
          last_name: nil,
        )

        Core::Order.upsert(
          order_attrs(node, source: "square", channel: "pos", customer_id: customer&.id),
          unique_by: [:tenant_id, :source, :source_order_id],
        )
        order = Core::Order.find_by(
          tenant_id: Current.tenant_id,
          source: "square",
          source_order_id: node["id"],
        )
        replace_order_lines!(order, node["line_items"])
        replace_payments!(order, square_payments(node))
      end
      Array(orders).length
    end

    # One-time: hydrate canonical orders from every ledger entry already
    # mirrored (order-level only; line/payment detail is unavailable).
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

    def upsert_customer!(source:, external_id:, email:, first_name:, last_name:, phone: nil)
      return if external_id.blank?

      Core::Customer.upsert(
        {
          tenant_id: Current.tenant_id,
          source: source,
          external_id: external_id,
          email: email,
          first_name: first_name,
          last_name: last_name,
          phone: phone,
          created_at: Time.current,
          updated_at: Time.current,
        },
        unique_by: [:tenant_id, :source, :external_id],
      )
      Core::Customer.find_by(tenant_id: Current.tenant_id, source: source, external_id: external_id)
    end

    # Replaces all line items for an order with the current payload, keeping
    # the canonical order_lines table in lock-step with the feed.
    def replace_order_lines!(order, line_items)
      nodes = if line_items.is_a?(Hash)
        Array(line_items["nodes"])
      else
        Array(line_items)
      end

      order.order_lines.delete_all
      nodes.each do |item|
        next if item.blank?

        order.order_lines.create!(
          tenant_id: Current.tenant_id,
          sku: item["sku"].presence || item["variation_name"],
          name: item["title"].presence || item["name"] || "Item",
          quantity: item["quantity"].to_i,
          unit_cents: money_cents(item.dig("originalUnitPriceSet", "shopMoney")) ||
            money_cents(item.dig("base_price_money")) || 0,
          line_cents: money_cents(item.dig("originalTotalSet", "shopMoney")) ||
            money_cents(item.dig("total_money")) || 0,
        )
      end
    end

    # Mirrors Shopify fulfillments (with carrier tracking) for an order. Newer
    # fulfillments are upserted; the order's `fulfilled` status is derived from
    # whether any fulfillment exists, keeping the canonical store in lock-step.
    def replace_fulfillments!(order, fulfillments)
      nodes = Array(fulfillments)
      return if nodes.empty? && order.fulfillments.none?

      nodes.each do |node|
        next if node.blank?

        tracking_info = node["trackingInfo"]
        tracking = tracking_info.is_a?(Array) ? tracking_info.first : tracking_info
        tracking ||= {}
        Core::Fulfillment.upsert(
          {
            tenant_id: Current.tenant_id,
            order_id: order.id,
            source: "shopify",
            source_fulfillment_id: node["id"],
            status: normalize_fulfillment_status(node["status"]),
            tracking_company: tracking["company"],
            tracking_number: tracking["number"],
            tracking_url: tracking["url"],
            fulfilled_at: parse_time(node["createdAt"]) || node["updatedAt"].presence && parse_time(node["updatedAt"]),
            created_at: Time.current,
            updated_at: Time.current,
          },
          unique_by: [:source, :source_fulfillment_id],
        )
      end
      order.fulfillments.reload
      if order.fulfillments.any? && order.may_fulfill?
        order.fulfill!
        order.update_columns(updated_at: Time.current)
      end
    end

    def replace_payments!(order, payments)
      order.payments.delete_all
      payments.each do |payment|
        order.payments.create!(
          tenant_id: Current.tenant_id,
          method: payment[:method],
          amount_cents: payment[:amount_cents],
          status: "completed",
          reference: payment[:reference],
          paid_at: payment[:paid_at] || Time.current,
        )
      end
    end

    # Shopify returns a paymentGatewayNames array, not itemized tenders; infer
    # a single tender from the order total for tender-type reporting.
    def shopify_payments(node)
      gross = (node.dig("currentTotalPriceSet", "shopMoney", "amount").to_f * 100).round
      return [] if gross.zero?

      gateways = Array(node["paymentGatewayNames"])
      method = if gateways.any? { |g| g.to_s.downcase.include?("gift") }
        "gift_card"
      elsif gateways.any? { |g| g.to_s.downcase.include?("cash") }
        "cash"
      else
        "card"
      end
      [{
        method: method,
        amount_cents: gross,
        reference: node["name"],
        paid_at: parse_time(node["createdAt"]),
      }]
    end

    # Square orders carry an itemized `tenders` array.
    def square_payments(node)
      tenders = Array(node["tenders"])
      return [] if tenders.empty?

      tenders.filter_map do |tender|
        amount = (tender.dig("amount_money", "amount").to_i || 0).abs
        next if amount.zero?

        {
          method: map_square_tender(tender["type"]),
          amount_cents: amount,
          reference: tender["id"],
          paid_at: parse_time(tender["created_at"]) || parse_time(node["created_at"]),
        }
      end
    end

    def map_square_tender(type)
      case type.to_s.upcase
      when "CASH" then "cash"
      when "GIFT_CARD" then "gift_card"
      when "CARD", "SQUARE_ACCOUNT", "CASH_APP_PAY", "BUY_NOW_PAY_LATER" then "card"
      else "other"
      end
    end

    def order_attrs(data = nil, channel: nil, customer_id: nil, source: nil, **kw)
      data = kw if data.nil?
      gross_cents = money_cents(data.dig("currentTotalPriceSet", "shopMoney")) ||
        money_cents(data.dig("total_money")) || (data[:grossCents] || data["grossCents"]).to_i
      tax_cents = money_cents(data.dig("currentTotalTaxSet", "shopMoney")) ||
        money_cents(data.dig("total_tax_money")) || 0

      {
        tenant_id: Current.tenant_id,
        source: source || data[:source] || data["source"] || "square",
        source_order_id: data[:sourceOrderId] || data["sourceOrderId"] || data["id"],
        order_number: data[:orderName] || data["orderName"] || data["name"] ||
          "SQ-#{data["id"].to_s.slice(0, 12)}",
        channel: channel || data[:channel] || data["channel"],
        customer_id: customer_id,
        location_id: data["location_id"] || data[:locationId] || data["locationId"],
        occurred_at: parse_time(data["createdAt"] || data["created_at"]) ||
          (data[:occurredAt] || data["occurredAt"]) || Time.current,
        gross_cents: gross_cents,
        tax_cents: tax_cents,
        status: normalize_status(data["displayFinancialStatus"] || data["state"] ||
          data[:status] || data["status"]),
        line_items: data["lineItems"]&.dig("nodes")&.length ||
          data["line_items"]&.length || (data[:lineItems] || data["lineItems"]).to_i,
        currency: data.dig("currentTotalPriceSet", "shopMoney", "currencyCode") ||
          data.dig("total_money", "currency") || data[:currency] || data["currency"] || "USD",
        shipping_name: address_attr(data, "name"),
        shipping_address1: address_attr(data, "address1"),
        shipping_address2: address_attr(data, "address2"),
        shipping_city: address_attr(data, "city"),
        shipping_province: address_attr(data, "province"),
        shipping_zip: address_attr(data, "zip"),
        shipping_country: address_attr(data, "country"),
        shipping_phone: address_attr(data, "phone"),
        created_at: Time.current,
        updated_at: Time.current,
      }
    end

    def address_attr(data, key)
      value = data.dig("shippingAddress", key) || data.dig("shipping_address", key)
      value.presence
    end

    def normalize_fulfillment_status(raw)
      case raw.to_s.downcase
      when "fulfilled", "delivered" then "fulfilled"
      when "in_transit", "out_for_delivery" then "in_transit"
      when "attempted_delivery", "failure" then "delivered"
      else "pending"
      end
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

    # Converts a platform money payload into cents. Shopify money amounts are
    # dollar strings ("63.60") needing *100; Square money amounts are already
    # integer cents and pass through unchanged.
    def money_cents(hash)
      return if hash.blank?

      amount = hash["amount"]
      amount.is_a?(Numeric) ? amount.to_i : (amount.to_f * 100).round
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    rescue ArgumentError
      nil
    end
  end
end
