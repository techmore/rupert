# frozen_string_literal: true

# Order detail: full invoice / receipt view with shipping, tracking, and line
# items. Read-only except for manual fulfillment actions.
class OrdersController < AuthenticatedController
  before_action :set_order

  def show
    authorize(:module, :sales_read?)
    @fulfillments = @order.fulfillments.order(created_at: :desc)
    @refunds = @order.refunds.order(refunded_at: :desc)
    @doc = params[:doc].to_s == "packing_slip" ? "packing_slip" : "invoice"
  end

  # Office workflow: record a shipped package with carrier tracking.
  def add_tracking
    authorize(:module, :sales_write?)
    fulfillment = @order.fulfillments.build(
      tenant_id: Current.tenant_id,
      tracking_company: params[:tracking_company].presence,
      tracking_number: params[:tracking_number].presence,
      tracking_url: params[:tracking_url].presence,
      fulfilled_at: Time.current,
      status: "fulfilled",
    )
    fulfillment.save!
    @order.fulfill! if @order.may_fulfill?
    ActivityLogger.log(
      "tracking_added",
      subject: @order,
      details: "#{fulfillment.tracking_company} #{fulfillment.tracking_number}".strip,
    )
    redirect_to(order_path(@order), notice: "Tracking added — order marked fulfilled.")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to(order_path(@order), alert: e.record.errors.full_messages.join(", "))
  end

  # Process a refund (partial or full). Recorded against the order; a full
  # refund transitions the financial status to refunded.
  def refund
    authorize(:module, :sales_write?)
    refund = @order.record_refund!(
      amount_cents: params[:amount_cents].to_i,
      method: params[:method].presence || "card",
      reason: params[:reason].presence,
      reference: params[:reference].presence,
    )
    cents = params[:amount_cents].to_i
    ActivityLogger.log("refund_recorded", subject: @order, details: "$#{format("%.2f", cents / 100.0)} · #{refund.method}")
    redirect_to(order_path(@order), notice: "Refund of $#{format("%.2f", cents / 100.0)} recorded.")
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to(order_path(@order), alert: e.message)
  end

  # Office fulfillment pipeline (feature flag off by default): move the order
  # through pending → in_transition → shipped → arrived → completed.
  def update_fulfillment_status
    authorize(:module, :sales_write?)
    unless FeatureFlag.enabled?(:fulfillment_workflow)
      return redirect_to(order_path(@order), alert: "Fulfillment workflow is disabled.")
    end

    status = params[:status].to_s
    unless Core::Order::FULFILLMENT_STATUSES.include?(status)
      return redirect_to(order_path(@order), alert: "Unknown fulfillment status.")
    end

    if @order.advance_fulfillment_status!(status)
      ActivityLogger.log("fulfillment_status", subject: @order, details: "marked #{status}")
      redirect_to(order_path(@order), notice: "Order marked #{status}.")
    else
      redirect_to(order_path(@order), alert: "Can't move from #{@order.fulfillment_status} to #{status}.")
    end
  end

  private

  def set_order
    @order = Core::Order.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end
end
