# frozen_string_literal: true

# Public, token-gated warehouse-sale page. The token in the URL is the access
# control — the page is intentionally not linked anywhere in the app.
class WarehouseSalesController < ApplicationController
  layout "warehouse_sale"
  include WarehousePortal

  skip_before_action :require_login
  skip_before_action :load_last_sync
  before_action :load_share

  def show
    @cart = current_cart
    @products = ShopifyProduct.includes(variants: :levels).order(:title)
  end
end
