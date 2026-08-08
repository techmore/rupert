# frozen_string_literal: true

# Port of seedAlerts from the legacy script — opens low/out-of-stock alerts
# for tracked variants, without duplicating open alerts per variant.
class AlertGenerator
  THRESHOLD = 5

  class << self
    def sync!
      ShopifyVariant.where.not(sku: [nil, ""]).find_each do |variant|
        sync_variant!(variant.id, variant.sku, variant.inventoryQuantity.to_i)
      end
    end

    def sync_variant!(variant_id, sku, quantity)
      return if quantity > THRESHOLD

      existing = StockAlert.find_by(shopifyVariantId: variant_id, status: "open")
      return if existing

      StockAlert.create!(
        shopifyVariantId: variant_id,
        sku: sku,
        quantity: quantity,
        threshold: THRESHOLD,
        status: "open",
        note: quantity <= 0 ? "Out of stock" : "Low stock — below threshold of #{THRESHOLD}",
        createdAt: Time.current,
      )
    end
  end
end
