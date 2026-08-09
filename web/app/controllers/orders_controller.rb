# frozen_string_literal: true

# Order detail: full invoice / receipt view with shipping, tracking, and line
# items. Read-only except for manual fulfillment actions.
class OrdersController < AuthenticatedController
  before_action :set_order

  def show
    authorize(:module, :sales_read?)
    @fulfillments = @order.fulfillments.order(created_at: :desc)
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
    redirect_to(order_path(@order), notice: "Tracking added — order marked fulfilled.")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to(order_path(@order), alert: e.record.errors.full_messages.join(", "))
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
