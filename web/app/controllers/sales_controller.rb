# frozen_string_literal: true

# Daily sales journal ("spreadstyle" layout): every sale of a day listed in
# arrival order across the hour ladder, showing where each sale occurred.
class SalesController < AuthenticatedController
  def index
    authorize(:module, :sales_read?)

    @date = begin
      Date.parse(params[:date])
    rescue
      Time.current.to_date
    end
    @window_days = params[:window].present? ? params[:window].to_i.clamp(1, 365) : 30

    since = Time.current - @window_days.days
    @source = params[:source].presence || "all"
    source_scope = @source == "all" ? nil : @source
    @sources = Core::Order.since(since).distinct.pluck(:source).sort

    @sales = Core::Order.since(since).by_source(source_scope)
    @total_cents = @sales.sum(:gross_cents)
    @sales = @sales.recent(500)

    @hourly = hourly_pivot(@date, source_scope)
    @day_sales = Core::Order.on_day(@date).by_source(source_scope).includes(:fulfillments, :location).order(occurred_at: :asc)
    @day_total_cents = @day_sales.sum(:gross_cents)
    @locations = Location.order(:name).pluck(:name, :id)
    @revenue_series = DashboardPresenter.new.revenue_series(days: @window_days, source: source_scope)
    @hourly_series = DashboardPresenter.new.hourly_series(days: @window_days, source: source_scope)
    @source_breakdown = DashboardPresenter.new.source_breakdown(days: @window_days)
  end

  # Batch print view: every order on a day as a packing slip (or invoice),
  # laid out one per page for the shipping desk.
  def print
    authorize(:module, :sales_read?)
    @date = params[:date].present? ? Date.parse(params[:date]) : Time.current.to_date
    @doc = params[:doc].to_s == "invoice" ? "invoice" : "packing_slip"
    @orders = Core::Order.on_day(@date).includes(:customer, :order_lines, :fulfillments).order(occurred_at: :asc)
    render(layout: "print")
  rescue ArgumentError
    redirect_to(sales_path, alert: "Invalid date.")
  end

  private

  # rows: hour (9..21), columns: location name -> gross cents + count
  def hourly_pivot(date, source = nil)
    rows = (9..21).map { |h| { hour: h, label: Time.zone.parse("#{h}:00").strftime("%-I %p"), cells: {} } }
    orders = Core::Order.on_day(date).by_source(source).includes(:location)

    by_hour = orders.group_by { |o| o.occurred_at.hour }
    by_hour.each do |hour, bucket|
      row = rows.find { |r| r[:hour] == hour }
      next unless row

      bucket.group_by { |o| o.location&.name || "Unknown" }.each do |name, group|
        row[:cells][name] = { cents: group.sum(&:gross_cents), count: group.size }
      end
    end
    rows
  end
end
