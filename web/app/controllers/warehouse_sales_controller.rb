# frozen_string_literal: true

# Public, token-gated warehouse-sale page. The token in the URL is the access
# control — the page is intentionally not linked anywhere in the app.
class WarehouseSalesController < ApplicationController
  layout "warehouse_sale"
  skip_before_action :require_login
  skip_before_action :load_last_sync

  def show
    @share = WarehouseShare.unscoped.includes(:tiers).find_by(token: params[:token])
    return render_404 unless @share&.active?

    Current.tenant = @share.tenant
    @products = ShopifyProduct.includes(variants: :levels).order(:title)
  end

  private

  def render_404
    render plain: "Not found", status: :not_found
  end
end
