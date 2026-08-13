# frozen_string_literal: true

# Port of seedAlerts from the legacy script — opens low/out-of-stock alerts
# for tracked variants, without duplicating open alerts per variant.
class AlertGenerator
  # Backwards-compatible default when no tenant context / settings are set.
  THRESHOLD = 5

  class << self
    def sync!
      ShopifyVariant.where.not(sku: [nil, ""]).find_each do |variant|
        sync_variant!(variant.id, variant.sku, variant.inventoryQuantity.to_i)
      end
    end

    def sync_variant!(variant_id, sku, quantity)
      threshold = threshold_for_current_tenant
      return resolve_recovered!(variant_id, quantity, threshold) if quantity > threshold

      existing = StockAlert.find_by(shopifyVariantId: variant_id, status: "open")
      return if existing

      StockAlert.create!(
        shopifyVariantId: variant_id,
        sku: sku,
        quantity: quantity,
        threshold: threshold,
        status: "open",
        note: quantity <= 0 ? "Out of stock" : "Low stock — below threshold of #{threshold}",
        createdAt: Time.current,
      )
    end

    # Close the alert loop: when stock recovers above the threshold, mark any
    # open alerts for that variant resolved instead of leaving them open until
    # a human resolves them manually.
    def resolve_recovered!(variant_id, quantity, threshold)
      open_alerts = StockAlert.where(shopifyVariantId: variant_id, status: "open")
      return if open_alerts.none?

      open_alerts.update_all(
        status: "resolved",
        resolvedAt: Time.current,
        quantity: quantity,
        note: "Stock recovered to #{quantity} (above threshold of #{threshold})",
      )
    end

    def threshold_for_current_tenant
      return THRESHOLD if Current.tenant_id.blank?

      TenantSettings.low_stock_threshold_int
    end
  end
end
