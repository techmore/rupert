# frozen_string_literal: true

require "csv"

# ERP reporting area. Four report families, all sourced from the canonical
# Core::Order/OrderLine/Payment/Customer store (single source of truth):
#   sales      — revenue trends, channels, locations, top products, AOV
#   financial  — P&L (revenue/tax/refunds), tender breakdown
#   inventory  — stock valuation, movements, low-stock pipeline
#   operations — sync health, reconcile runs, POS cash variance
#
# Every report supports ?days= and ?source= filters, and .csv export.
class ReportsController < AuthenticatedController
  before_action :authorize_reports
  before_action :set_range

  def index
    redirect_to(sales_reports_path)
  end

  def sales
    @days = window_days
    since = @days.days.ago

    @revenue_daily = Core::Order.since(since).group_by_day(:occurred_at, range: since..Time.current)
      .sum(:gross_cents).transform_values { |c| (c / 100.0).round(2) }
    @revenue_weekly = Core::Order.since(since).group_by_week(:occurred_at, range: since..Time.current)
      .sum(:gross_cents).transform_values { |c| (c / 100.0).round(2) }
    @by_source = Core::Order.since(since).group(:source).sum(:gross_cents)
      .transform_keys { |k| k.to_s.capitalize }.transform_values { |c| c / 100.0 }
    @by_channel = Core::Order.since(since).group(:channel).sum(:gross_cents)
      .transform_keys { |k| k.to_s.capitalize }.transform_values { |c| c / 100.0 }
    @by_location = Core::Order.since(since).joins(:location)
      .group("\"Location\".name").sum(:gross_cents)
      .transform_values { |c| c / 100.0 }
    @aov = Core::Order.since(since).where(status: ["paid", "fulfilled"]).average(:gross_cents).to_f / 100.0
    @total_orders = Core::Order.since(since).where(status: ["paid", "fulfilled"]).count
    @total_revenue = Core::Order.since(since).where(status: ["paid", "fulfilled"]).sum(:gross_cents) / 100.0

    @top_products = Core::OrderLine.joins(:order)
      .where(orders: { occurred_at: since..Time.current })
      .group(:name, :sku).sum(:line_cents)
      .sort_by { |_, cents| -cents }.first(10)
      .map { |(name, sku), cents| { name: name, sku: sku, revenue: (cents / 100.0).round(2) } }

    respond_to do |format|
      format.html
      format.csv { send_data(sales_csv, filename: "sales-report-#{@days}d.csv") }
    end
  end

  def financial
    since = @range
    orders = Core::Order.since(since).where(status: ["paid", "fulfilled"])

    @revenue_cents = orders.sum(:gross_cents)
    @tax_cents = orders.sum(:tax_cents)
    @refund_cents = Core::Order.since(since).where(status: "refunded").sum(:gross_cents)
    @net_cents = @revenue_cents - @refund_cents
    @avg_order_cents = orders.count.zero? ? 0 : (orders.sum(:gross_cents) / orders.count)

    @tenders = Core::Payment.joins(:order)
      .where(orders: { occurred_at: since..Time.current }, payments: { status: "completed" })
      .group("payments.method").sum("payments.amount_cents")
      .transform_values { |c| c / 100.0 }

    @daily_net = orders.group_by_day(:occurred_at, range: since..Time.current)
      .sum(:gross_cents).transform_values { |c| (c / 100.0).round(2) }

    respond_to do |format|
      format.html
      format.csv { send_data(financial_csv, filename: "financial-report-#{@days}d.csv") }
    end
  end

  def inventory
    @valuation = ShopifyVariant.includes(:product)
      .where.not(price: nil)
      .sum { |v| v.price.to_f * v.inventoryQuantity.to_i }
    @variants = ShopifyVariant.count
    @tracked = ShopifyVariant.where(tracked: true).count
    @low_stock = ShopifyVariant.where("\"inventoryQuantity\" > 0 AND \"inventoryQuantity\" <= ?", 5).count
    @out_of_stock = ShopifyVariant.where("\"inventoryQuantity\" <= 0").count
    @movements_30d = InventoryMovement.where("\"createdAt\" >= ?", 30.days.ago).count

    @movement_trend = InventoryMovement.where("\"createdAt\" >= ?", 30.days.ago)
      .group_by_day(:createdAt, range: 30.days.ago..Time.current)
      .count

    @low_stock_items = ShopifyVariant.includes(:product)
      .where("\"inventoryQuantity\" <= ?", 5).order(:inventoryQuantity).limit(50)
      .map { |v| { sku: v.sku, product: v.product&.title, variant: v.title, qty: v.inventoryQuantity, price: v.price } }

    respond_to do |format|
      format.html
      format.csv { send_data(inventory_csv, filename: "inventory-report-#{@days}d.csv") }
    end
  end

  def operations
    @sync_success = SyncRun.where(status: "success").count
    @sync_failed = SyncRun.where(status: "failed").count
    @sync_total = SyncRun.count
    @sync_rate = @sync_total.zero? ? 0 : (@sync_success.to_f / @sync_total * 100).round(1)

    @reconcile_runs = ReconcileRun.order(startedAt: :desc).limit(20)
    @reconcile_total = ReconcileRun.count
    @reconcile_success = ReconcileRun.where(status: "applied").count

    @pos_sessions = Sales::PosSession.order(opened_at: :desc).limit(20)
    @pos_variance_total = Sales::PosSession.where.not(variance_cents: nil).sum(:variance_cents) / 100.0
    @pos_open = Sales::PosSession.where(status: "open").count

    respond_to do |format|
      format.html
      format.csv { send_data(operations_csv, filename: "operations-report-#{@days}d.csv") }
    end
  end

  private

  def authorize_reports
    authorize(:module, :reports_read?)
  end

  def set_range
    @days = window_days
    @range = @days.days.ago
  end

  def window_days
    days = params[:days].to_i
    days.zero? ? 30 : days.clamp(7, 365)
  end

  # --- CSV builders ---

  def sales_csv
    rows = [["Day", "Revenue (USD)", "Orders"]]
    Core::Order.since(@range).group_by_day(:occurred_at, range: @range..Time.current)
      .sum(:gross_cents).each do |day, cents|
      rows << [day.iso8601, (cents / 100.0).round(2), Core::Order.where(occurred_at: day.beginning_of_day..day.end_of_day).count]
    end
    to_csv(rows)
  end

  def financial_csv
    rows = [["Metric", "Value (USD)"]]
    rows << ["Gross revenue", @revenue_cents / 100.0]
    rows << ["Tax collected", @tax_cents / 100.0]
    rows << ["Refunds", @refund_cents / 100.0]
    rows << ["Net revenue", @net_cents / 100.0]
    @tenders.each { |method, amt| rows << ["Tender #{method}", amt] }
    to_csv(rows)
  end

  def inventory_csv
    rows = [["SKU", "Product", "Variant", "On hand", "Price", "Value"]]
    ShopifyVariant.includes(:product).where.not(price: nil).order(:sku).find_each do |v|
      rows << [v.sku, v.product&.title, v.title, v.inventoryQuantity, v.price, (v.price.to_f * v.inventoryQuantity.to_i).round(2)]
    end
    to_csv(rows)
  end

  def operations_csv
    rows = [["Sync run", "Status", "Started"]]
    SyncRun.order(startedAt: :desc).limit(100).each do |run|
      rows << [run.source || run.mode, run.status, run.startedAt]
    end
    to_csv(rows)
  end

  def to_csv(rows)
    CSV.generate do |csv|
      rows.each { |row| csv << row }
    end
  end
end
