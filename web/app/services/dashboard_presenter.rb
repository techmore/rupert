# frozen_string_literal: true

# Aggregates all dashboard statistics in one place. Expensive computations are
# cached in DataCache (version-keyed, invalidated on sync / manual mutations);
# cheap counters and the always-live "recent" lists stay fresh per request.
class DashboardPresenter
  attr_reader :product_count,
    :variant_count,
    :sku_link_count,
    :open_alerts,
    :stockouts,
    :recent_runs,
    :recent_syncs,
    :recent_alerts

  def initialize
    @product_count = ShopifyProduct.count
    @variant_count = ShopifyVariant.count
    @sku_link_count = SkuLink.count
    @open_alerts = StockAlert.open.count
    @stockouts = StockAlert.open.where("quantity <= 0").count
    @recent_runs = ReconcileRun.recent(5)
    @recent_syncs = SyncRun.recent(5)
    @recent_alerts = StockAlert.open.order(createdAt: :desc).limit(5)
  end

  # --- Cached (version-keyed, invalidated on sync/mutations) ---

  def linked_count
    @linked_count ||= DataCache.fetch("dashboard/linked_count") { SkuLink.linked.count }
  end

  def drifting
    @drifting ||= DataCache.fetch("dashboard/drifting") do
      ids = SkuLink.linked.pluck(:shopifyVariantId, :squareVariationId)
      shopify_totals = InventoryLevel.where(shopifyVariantId: ids.map(&:first))
        .group(:shopifyVariantId).sum(:quantity)
      square_totals = InventoryLevel.where(squareVariationId: ids.map(&:second))
        .group(:squareVariationId).sum(:quantity)
      ids.count do |shopify_id, square_id|
        shopify_totals[shopify_id].to_i != square_totals[square_id].to_i
      end
    end
  end

  def reconcile_summary
    @reconcile_summary ||= DataCache.fetch("dashboard/reconcile_summary") do
      Reconciler.summary(Reconciler.build_rows)
    end
  end

  def today_revenue
    @today_revenue ||= DataCache.fetch("dashboard/today_revenue") { today_ledger.sum(:grossCents) }
  end

  def today_orders
    @today_orders ||= DataCache.fetch("dashboard/today_orders") { today_ledger.count }
  end

  def today_groups
    @today_groups ||= DataCache.fetch("dashboard/today_groups") do
      today_ledger.group(:source)
        .pluck(:source, Arel.sql("SUM(\"grossCents\") AS gross"), Arel.sql("COUNT(*) AS count"))
    end
  end

  def yesterday_revenue
    @yesterday_revenue ||= DataCache.fetch("dashboard/yesterday_revenue") do
      LedgerEntry.where(occurredAt: (today_start - 1.day)...today_start).sum(:grossCents)
    end
  end

  def week_revenue
    @week_revenue ||= DataCache.fetch("dashboard/week_revenue") { LedgerEntry.since(7.days.ago).sum(:grossCents) }
  end

  def month_revenue
    @month_revenue ||= DataCache.fetch("dashboard/month_revenue") { LedgerEntry.since(30.days.ago).sum(:grossCents) }
  end

  def ledger_groups
    @ledger_groups ||= DataCache.fetch("dashboard/ledger_groups") do
      LedgerEntry.since(30.days.ago).group(:source)
        .pluck(:source, Arel.sql("SUM(\"grossCents\") AS gross"), Arel.sql("COUNT(*) AS count"))
    end
  end

  # Revenue per day over the last N days, for chartkick line/area charts.
  def revenue_series(days: 30, source: nil)
    key = "dashboard/revenue_series/#{days}/#{source || "all"}"
    DataCache.fetch(key, ttl: 10.minutes) do
      scope = Core::Order.since(days.days.ago)
      scope = scope.where(source: source) if source.present?
      scope.group_by_day(:occurred_at, default_value: 0, range: days.days.ago..Time.current).sum(:gross_cents)
        .transform_values { |cents| (cents / 100.0).round(2) }
    end
  end

  # Sales count per day over the last N days.
  def sales_volume_series(days: 30, source: nil)
    key = "dashboard/sales_volume/#{days}/#{source || "all"}"
    DataCache.fetch(key, ttl: 10.minutes) do
      scope = Core::Order.since(days.days.ago)
      scope = scope.where(source: source) if source.present?
      scope.group_by_day(:occurred_at, default_value: 0, range: days.days.ago..Time.current).count
    end
  end

  # Gross per hour across all days in range — powers the POS daily shape.
  def hourly_series(days: 30, source: nil)
    key = "dashboard/hourly_series/#{days}/#{source || "all"}"
    DataCache.fetch(key, ttl: 10.minutes) do
      scope = Core::Order.since(days.days.ago)
      scope = scope.where(source: source) if source.present?
      scope.group_by_hour_of_day(:occurred_at, range: days.days.ago..Time.current).sum(:gross_cents)
        .transform_values { |cents| (cents / 100.0).round(2) }
    end
  end

  # Gross per channel/source over the last N days.
  def source_breakdown(days: 30)
    key = "dashboard/source_breakdown/#{days}"
    DataCache.fetch(key, ttl: 10.minutes) do
      Core::Order.since(days.days.ago).group(:source).sum(:gross_cents)
        .transform_keys(&:capitalize).transform_values { |cents| cents / 100.0 }
    end
  end

  def last_sync
    @last_sync ||= SyncRun.order(startedAt: :desc).first
  end

  private

  def today_start
    Time.current.beginning_of_day
  end

  def today_ledger
    @today_ledger ||= LedgerEntry.since(today_start)
  end
end
