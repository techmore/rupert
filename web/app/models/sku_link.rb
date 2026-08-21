# frozen_string_literal: true

class SkuLink < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "SkuLink"
  self.primary_key = "id"

  belongs_to :shopify_variant,
    class_name: "ShopifyVariant",
    foreign_key: "shopifyVariantId",
    optional: true
  belongs_to :square_variation,
    class_name: "SquareVariation",
    foreign_key: "squareVariationId",
    optional: true

  scope :linked, -> { where.not(shopifyVariantId: nil).where.not(squareVariationId: nil) }
  scope :search, ->(q) {
    return all if q.blank?

    where("sku LIKE ?", "%#{q}%")
  }

  validates :sku, presence: true

  def linked?
    shopifyVariantId.present? && squareVariationId.present?
  end

  # SKUs linked to more than one Shopify variant — ambiguous for a single
  # Square-variation target. Used by Reconciler and InventoryMaintainer to
  # guard against half-applied shared-pool writes.
  def self.shared_skus
    SkuLink.linked.group(:sku).distinct.count("shopifyVariantId")
      .select { |_, count| count > 1 }.keys.map(&:downcase).to_set
  end
end
