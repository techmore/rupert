# frozen_string_literal: true

# Product / variant detail: quantities on both sides, level breakdowns,
# movements, alerts, and the SKU link to a Square variation.
class ShopifyVariantsController < AuthenticatedController
  before_action :set_variant

  def show
    authorize(:module, :inventory_read?)
    @product = @variant.product
    @link = @variant.sku_links.linked.first
    @movements = @variant.movements.order(createdAt: :desc).limit(20)
    @alerts = @variant.alerts.order(createdAt: :desc).limit(10)
    @shopify_levels = @variant.levels.order(:locationId)
    @square_variations = searchable_square_variations
  end

  # Manually link this Shopify variant to a Square variation (overrides any
  # auto link from sync).
  def link
    authorize(:module, :inventory_write?)
    square = SquareVariation.find_by!(tenant_id: Current.tenant_id, id: params[:square_variation_id])
    link = SkuLink.find_or_initialize_by(shopifyVariantId: @variant.id)
    link.tenant_id = Current.tenant_id
    link.squareVariationId = square.id
    link.sku = @variant.sku.presence || square.sku.presence || @variant.id
    link.matchSource = "manual"
    link.auto = false
    link.createdAt ||= Time.current
    link.save!
    redirect_to(shopify_variant_path(@variant), notice: "Linked #{@variant.title} to #{square.name}.")
  rescue ActiveRecord::RecordNotFound
    redirect_to(shopify_variant_path(@variant), alert: "Square variation not found.")
  end

  # Break the link; the next sync will re-link by SKU if SKUs still match.
  def unlink
    authorize(:module, :inventory_write?)
    @variant.sku_links.destroy_all
    redirect_to(shopify_variant_path(@variant), notice: "Link removed.")
  end

  private

  def set_variant
    @variant = ShopifyVariant.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  # Candidate Square variations to link against, preferring same-SKU matches.
  def searchable_square_variations
    scope = SquareVariation.where(tenant_id: Current.tenant_id)
    if @variant.sku.present?
      same_sku = scope.where(sku: @variant.sku).order(:name).limit(10)
      return same_sku if same_sku.any?

    end
    scope.order(:name).limit(20)
  end
end
