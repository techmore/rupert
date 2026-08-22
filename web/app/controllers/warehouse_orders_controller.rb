# frozen_string_literal: true

# Public order confirmation for a paid warehouse-sale order, keyed by the
# human-friendly order number shown after checkout.
class WarehouseOrdersController < ApplicationController
  layout 'warehouse_sale'
  include WarehousePortal

  skip_before_action :require_login
  skip_before_action :load_last_sync
  before_action :load_share

  def show
    @order = Core::Order.find_by!(tenant_id: @share.tenant_id, order_number: params[:order_number])
    @order_lines = Core::OrderLine.where(tenant_id: @share.tenant_id, order_id: @order.id)
    @payment = Core::Payment.find_by(order_id: @order.id)
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
