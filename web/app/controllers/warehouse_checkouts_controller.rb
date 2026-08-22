# frozen_string_literal: true

# Public checkout for a warehouse-sale cart. Card data is tokenized in the
# browser by Accept.js (hosted fields); only the payment nonce reaches the
# server. On approval a canonical Core::Order is created and the cart is
# checked out.
class WarehouseCheckoutsController < ApplicationController
  layout 'warehouse_sale'
  include WarehousePortal

  skip_before_action :require_login
  skip_before_action :load_last_sync
  before_action :load_share
  before_action :require_cart

  def show
    @cart = current_cart
    @client_key = AuthorizeNetClient.client_key
    @login_id = AuthorizeNetClient.login_id
    @accept_js_url = AuthorizeNetClient.accept_js_url
  end

  def create
    result = WarehouseCheckoutService.call(
      share: @share,
      cart: current_cart,
      shipping: order_params,
      payment_nonce: params[:payment_nonce],
      data_descriptor: params[:data_descriptor]
    )

    if result.success?
      clear_cart_token!
      redirect_to(warehouse_order_path(@share.token, result.order.order_number), notice: 'Order confirmed.')
    else
      @cart = current_cart
      @client_key = AuthorizeNetClient.client_key
      @login_id = AuthorizeNetClient.login_id
      @accept_js_url = AuthorizeNetClient.accept_js_url
      flash.now[:alert] = result.error
      render(:show, status: :unprocessable_entity)
    end
  end

  private

  def require_cart
    render_404 if current_cart.items.none?
  end

  def order_params
    params.permit(
      :shipping_name,
      :shipping_address1,
      :shipping_address2,
      :shipping_city,
      :shipping_province,
      :shipping_zip,
      :shipping_country,
      :shipping_phone,
      :email
    ).to_h.symbolize_keys
  end
end
