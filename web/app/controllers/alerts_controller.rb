# frozen_string_literal: true

class AlertsController < AuthenticatedController
  def index
    @status = params[:status].presence || "open"
    @alerts = StockAlert.by_status(@status).order(createdAt: :desc).limit(100)
    @counts = StockAlert.group(:status).count
  end

  def update_status
    alert = StockAlert.find(params[:id])
    next_status = params[:status].to_s
    if ["resolved", "ignored"].include?(next_status)
      alert.update!(status: next_status, resolvedAt: next_status == "resolved" ? Time.current : nil)
    end
    redirect_to(alerts_path(status: alert.status))
  end
end
