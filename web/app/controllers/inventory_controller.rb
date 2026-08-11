# frozen_string_literal: true

class InventoryController < AuthenticatedController
  before_action :authorize_read

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
    @variant_qtys = variant_quantity_map(@products)
  end

  private

  def authorize_read
    authorize(:module, :inventory_read?)
  end

  # Precompute per-variant quantities and the linked Square quantity so the
  # index view doesn't run per-row queries.
  def variant_quantity_map(products)
    map = {}
    products.each do |product|
      product.variants.each do |variant|
        link = variant.sku_links.find(&:linked?)
        map[variant.id] = {
          shopify_qty: variant.levels.sum(&:quantity),
          link: link,
          square_qty: link ? link.square_variation&.levels&.sum(&:quantity) : nil,
        }
      end
    end
    map
  end
end
