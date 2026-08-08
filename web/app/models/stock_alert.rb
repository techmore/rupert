# frozen_string_literal: true

class StockAlert < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "StockAlert"
  self.primary_key = "id"

  belongs_to :shopify_variant, class_name: "ShopifyVariant",
    foreign_key: "shopifyVariantId", optional: true
  belongs_to :square_variation, class_name: "SquareVariation",
    foreign_key: "squareVariationId", optional: true

  scope :open, -> { where(status: "open") }
  scope :by_status, ->(status) { status.present? && status != "all" ? where(status: status) : all }

  def product_name
    shopify_variant&.product&.title || square_variation&.item&.name
  end

  def variant_name
    shopify_variant&.title || square_variation&.name
  end
end
