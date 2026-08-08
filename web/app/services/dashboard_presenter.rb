# frozen_string_literal: true

# Aggregates all dashboard statistics in one place.
class DashboardPresenter
  attr_reader :product_count, :variant_count, :sku_link_count, :linked_count,
    :open_alerts, :drifting, :recent_runs, :recent_syncs, :recent_alerts,
    :ledger_groups

  def initialize
    linked_links = SkuLink.linked.includes(shopify_variant: :levels, square_variation: :levels)

    @product_count = ShopifyProduct.count
    @variant_count = ShopifyVariant.count
    @sku_link_count = SkuLink.count
    @linked_count = linked_links.length
    @drifting = linked_links.count do |link|
      InventoryLevel.total_for_variant(link.shopifyVariantId) != InventoryLevel.total_for_variation(link.squareVariationId)
    end
    @open_alerts = StockAlert.open.count
    @recent_runs = ReconcileRun.recent(5)
    @recent_syncs = SyncRun.recent(5)
    @recent_alerts = StockAlert.open.order(createdAt: :desc).limit(5)

    since = Time.current - 30.days
    @ledger_groups = LedgerEntry.since(since).group(:source)
      .pluck(:source, Arel.sql("SUM(grossCents) AS gross"), Arel.sql("COUNT(*) AS count"))
  end
end
