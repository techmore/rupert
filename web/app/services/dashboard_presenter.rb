# frozen_string_literal: true

# Aggregates all dashboard statistics in one place.
class DashboardPresenter
  attr_reader :product_count, :variant_count, :sku_link_count, :linked_count,
    :open_alerts, :drifting, :recent_runs, :recent_syncs, :recent_alerts,
    :ledger_groups, :today_revenue, :today_orders, :today_groups,
    :yesterday_revenue, :week_revenue, :month_revenue, :stockouts,
    :reconcile_summary

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
    @stockouts = StockAlert.open.where("quantity <= 0").count
    @recent_runs = ReconcileRun.recent(5)
    @recent_syncs = SyncRun.recent(5)
    @recent_alerts = StockAlert.open.order(createdAt: :desc).limit(5)

    today_start = Time.current.beginning_of_day
    today_ledger = LedgerEntry.since(today_start)
    @today_revenue = today_ledger.sum(:grossCents)
    @today_orders = today_ledger.count
    @today_groups = today_ledger.group(:source)
      .pluck(:source, Arel.sql("SUM(grossCents) AS gross"), Arel.sql("COUNT(*) AS count"))

    @yesterday_revenue = LedgerEntry.where(occurredAt: (today_start - 1.day)...today_start).sum(:grossCents)
    @week_revenue = LedgerEntry.since(7.days.ago).sum(:grossCents)
    @month_revenue = LedgerEntry.since(30.days.ago).sum(:grossCents)

    @ledger_groups = LedgerEntry.since(30.days.ago).group(:source)
      .pluck(:source, Arel.sql("SUM(grossCents) AS gross"), Arel.sql("COUNT(*) AS count"))

    @reconcile_summary = Reconciler.summary(Reconciler.build_rows)
  end

  def last_sync
    @last_sync ||= SyncRun.order(startedAt: :desc).first
  end
end
