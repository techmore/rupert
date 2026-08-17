# frozen_string_literal: true

class InventoryLevel < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "InventoryLevel"
  self.primary_key = "id"

  belongs_to :location,
    class_name: "Location",
    foreign_key: "locationId",
    optional: true
  belongs_to :shopify_variant,
    class_name: "ShopifyVariant",
    foreign_key: "shopifyVariantId",
    optional: true
  belongs_to :square_variation,
    class_name: "SquareVariation",
    foreign_key: "squareVariationId",
    optional: true

  def self.total_for_variant(variant_id)
    where(shopifyVariantId: variant_id).sum(:quantity)
  end

  def self.total_for_variation(variation_id)
    where(squareVariationId: variation_id).sum(:quantity)
  end
end
