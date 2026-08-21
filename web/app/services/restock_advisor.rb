# frozen_string_literal: true

# Turns low-stock alerts into restock decisions: recent sales pace per SKU,
# days of cover across both locations, and a suggested reorder quantity.
#
# Shopify and Square are separate locations with independent inventories, so
# "on hand" is the sum of both pools (both sell the same item), while the
# breakdown shows where it sits. The suggestion is deliberately simple and
# explainable: reorder enough to cover ~30 days at the trailing 30-day sales
# rate. It is advice, not an order — nothing here writes to any platform.
class RestockAdvisor
  Row = Struct.new(
    :alert,
    :sku,
    :shop_qty,
    :pos_qty,
    :sold_14,
    :sold_30,
    :days_of_cover,   # Float or nil (no recent sales)
    :suggested_qty,   # Integer or nil (no recent sales — restocking won't help)
    keyword_init: true,
  )

  COVER_DAYS = 30

  class << self
    # Returns { alert.id => Row } for the given alerts (any status).
    def for_alerts(alerts)
      skus = alerts.filter_map { |a| a.sku.presence&.downcase }.uniq
      return {} if skus.empty?

      stock = stock_by_sku(skus)
      sold14 = sold_by_sku(skus, 14.days)
      sold30 = sold_by_sku(skus, COVER_DAYS.days)

      alerts.to_h do |alert|
        key = alert.sku.to_s.downcase
        shop, pos = stock.fetch(key, [0, 0])
        on_hand = shop + pos
        s30 = sold30.fetch(key, 0)
        daily_rate = s30 / COVER_DAYS.to_f

        row = Row.new(
          alert: alert,
          sku: alert.sku,
          shop_qty: shop,
          pos_qty: pos,
          sold_14: sold14.fetch(key, 0),
          sold_30: s30,
          days_of_cover: daily_rate.positive? ? (on_hand / daily_rate).round(1) : nil,
          suggested_qty: daily_rate.positive? ? [((daily_rate * COVER_DAYS).ceil - on_hand), 0].max : nil,
        )
        [alert.id, row]
      end
    end

    private

    # sku => [shopify_units_total, square_units_total] for every location.
    def stock_by_sku(skus)
      variant_ids = ShopifyVariant.where("LOWER(\"sku\") IN (?)", skus).pluck(:id, :sku)
        .to_h { |id, sku| [id, sku.to_s.downcase] }
      variation_ids = SquareVariation.where("LOWER(\"sku\") IN (?)", skus).pluck(:id, :sku)
        .to_h { |id, sku| [id, sku.to_s.downcase] }

      shop = InventoryLevel.mirrored("shopify").where(shopifyVariantId: variant_ids.keys)
      pos = InventoryLevel.mirrored("square").where(squareVariationId: variation_ids.keys)

      shop_totals = Hash.new(0)
      shop.group_by(&:shopifyVariantId).each do |id, levels|
        shop_totals[variant_ids[id]] = levels.sum(&:quantity)
      end
      pos_totals = Hash.new(0)
      pos.group_by(&:squareVariationId).each do |id, levels|
        pos_totals[variation_ids[id]] = levels.sum(&:quantity)
      end

      skus.to_h { |sku| [sku, [shop_totals[sku], pos_totals[sku]]] }
    end

    # sku => units sold in the window, from the canonical order stream
    # (Shopify + Square + SwipeSimple all land there).
    def sold_by_sku(skus, window)
      Core::OrderLine.joins(:order)
        .where("LOWER(order_lines.\"sku\") IN (?)", skus)
        .where(orders: { occurred_at: window.ago.. })
        .group(:sku)
        .sum(:quantity)
        .to_h { |sku, qty| [sku.downcase, qty] }
    end
  end
end
