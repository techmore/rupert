# frozen_string_literal: true

class AlertsController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: %i[update_status bulk_update]

  def index
    @status = params[:status].presence || 'open'
    scope = StockAlert.by_status(@status)

    if @status == 'open'
      # Most urgent first: least days of cover at the top; SKUs with no
      # recent sales sink (restocking them isn't the fix). Only the sorted id
      # list is cached behind the DataCache version (alerts change only on
      # sync) — caching the full advice hash meant deserializing 593 AR-backed
      # structs on every request (~270ms).
      sorted_ids = DataCache.fetch('alerts/open_sorted_ids') do
        scoped = scope.open.includes(shopify_variant: :product, square_variation: :item).to_a
        advice = RestockAdvisor.for_alerts(scoped)
        # Cache the advice as plain numbers (AR-backed structs cost ~270ms to
        # deserialize on every request) alongside the sorted ids. Cache-store
        # failures must not break the page — fall back to the in-memory hash.
        plain = advice.transform_values { |r| [r.shop_qty, r.pos_qty, r.sold_14, r.sold_30, r.days_of_cover, r.suggested_qty] }
        begin
          Rails.cache.write("dc/#{Current.tenant_id}/alerts/plain_open/v#{DataCache.version}", plain,
            expires_in: DataCache::DEFAULT_TTL)
        rescue StandardError => e
          Rails.logger.warn("AlertsController: advice cache write failed (#{e.class}: #{e.message})")
        end
        sorted = scoped.sort_by { |a| [advice[a.id]&.days_of_cover.nil? ? 1 : 0, advice[a.id]&.days_of_cover || 0] }
                       .first(50)
        @plain_advice_fallback = plain
        sorted.map(&:id)
      end
      plain = (Rails.cache.read("dc/#{Current.tenant_id}/alerts/plain_open/v#{DataCache.version}") ||
               @plain_advice_fallback || {}).stringify_keys
      @alerts = StockAlert.where(id: sorted_ids)
                          .includes(shopify_variant: :product, square_variation: :item)
                          .index_by(&:id).values_at(*sorted_ids).compact
      @advice = plain.transform_values { |shop, pos, s14, s30, cover, suggested|
        RestockAdvisor::Row.new(alert: nil, sku: nil, shop_qty: shop, pos_qty: pos,
          sold_14: s14, sold_30: s30, days_of_cover: cover,
          suggested_qty: suggested)
      }
    else
      @alerts = DataCache.fetch("alerts/recent_#{@status}") do
        scope.order(createdAt: :desc)
             .includes(shopify_variant: :product, square_variation: :item).limit(50).to_a
      end
      @advice = DataCache.fetch("alerts/advice_#{@status}") { RestockAdvisor.for_alerts(@alerts) }
    end

    @counts = StockAlert.group(:status).count
  end

  def update_status
    alert = StockAlert.find(params[:id])
    next_status = params[:status].to_s
    if %w[resolved ignored].include?(next_status)
      alert.update!(status: next_status, resolvedAt: next_status == 'resolved' ? Time.current : nil)
    end
    redirect_to(alerts_path(status: alert.status))
  end

  # Bulk resolve/ignore for the checked rows on the alerts page.
  def bulk_update
    ids = Array(params[:alert_ids]).reject(&:blank?)
    next_status = params[:status].to_s
    if %w[resolved ignored].include?(next_status) && ids.any?
      StockAlert.where(tenant_id: Current.tenant_id, id: ids).each do |alert|
        alert.update!(status: next_status, resolvedAt: next_status == 'resolved' ? Time.current : nil)
      end
      flash[:notice] = "Updated #{ids.length} alert(s)."
    end
    redirect_to(alerts_path(status: params[:tab].presence || 'open'))
  end

  private

  def authorize_read
    authorize(:module, :alerts_read?)
  end

  def authorize_write
    authorize(:module, :alerts_write?)
  end
end
