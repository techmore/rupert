# frozen_string_literal: true

class AlertsController < AuthenticatedController
  before_action :authorize_read, only: :index
  before_action :authorize_write, only: %i[update_status bulk_update]

  def index
    @status = params[:status].presence || 'open'
    scope = StockAlert.by_status(@status)

    if @status == 'open'
      # Most urgent first: least days of cover at the top; SKUs with no
      # recent sales sink (restocking them isn't the fix).
      @advice = RestockAdvisor.for_alerts(scope.open.to_a)
      @alerts = scope.open.sort_by do |a|
        [@advice[a.id]&.days_of_cover.nil? ? 1 : 0, @advice[a.id]&.days_of_cover || 0]
      end
                     .first(50)
    else
      @alerts = scope.order(createdAt: :desc).limit(50)
      @advice = RestockAdvisor.for_alerts(@alerts)
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
