# frozen_string_literal: true

class InventoryController < AuthenticatedController
  def index
    @q = params[:q].to_s.strip
    @products = ShopifyProduct.order(title: :asc).limit(40)
    if @q.present?
      @products = @products.where(
        "title LIKE ? OR id IN (SELECT productId FROM \"ShopifyVariant\" WHERE sku LIKE ?)",
        "%#{@q}%",
        "%#{@q}%",
      )
    end
    @products = @products.includes(variants: [{ sku_links: { square_variation: :levels } }, :levels])
  end
end
