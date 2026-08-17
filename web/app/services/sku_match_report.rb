# frozen_string_literal: true

# Full-catalog Shopify vs Square SKU matching report, used by the
# "Recommend SKU download" button on the Inventory page. Every Shopify
# variant gets one row with its Shopify SKU, the linked Square variation's
# SKU (when linked), and a status explaining whether the pair is consistent
# or what's blocking it:
#   ok                      — Shopify and Square share the same SKU
#   duplicate-across-products — this SKU is reused by another product
#   missing-shopify-sku     — Shopify variant has no SKU (Square can't link)
#   not-linked              — no Square variation is linked to this variant
#   square-missing-sku      — linked Square variation has no SKU
#   sku-mismatch            — linked pair's SKUs differ between platforms
#
# Plan-only: proposes unique SKUs for the duplicate cases (see
# SkuRemediationPlanner) but never writes anything.
class SkuMatchReport
  Row = Struct.new(
    :product, :variant, :shopify_sku, :square_sku, :linked, :status, :proposed_sku, :note,
    keyword_init: true,
  )

  def self.rows
    new.rows
  end

  def rows
    proposals = SkuRemediationPlanner.plan.index_by(&:variant_id)
    duplicate_skus = SkuRemediationPlanner.shared_skus
    link_map = SkuLink.linked.index_by(&:shopifyVariantId)
    square_by_id = SquareVariation.all.index_by(&:id)

    ShopifyProduct.order(:title).includes(:variants).flat_map do |product|
      product.variants.sort_by(&:title).map do |variant|
        link = link_map[variant.id]
        square = link && square_by_id[link.squareVariationId]
        shopify_sku = variant.sku.presence || ""
        square_sku = square&.sku.presence || ""
        proposal = proposals[variant.id]
        status, note = classify(variant, link, square, duplicate_skus)
        Row.new(
          product: product.title,
          variant: variant.title,
          shopify_sku: shopify_sku,
          square_sku: square_sku,
          linked: link ? "yes" : "no",
          status: status,
          proposed_sku: proposal&.proposed_sku.to_s,
          note: note,
        )
      end
    end
  end

  def self.csv
    require "csv"
    CSV.generate do |out|
      out << ["Product", "Variant", "Shopify SKU", "Square SKU", "Linked", "Status", "Proposed SKU", "Note"]
      rows.each do |row|
        out << [row.product, row.variant, row.shopify_sku, row.square_sku, row.linked, row.status, row.proposed_sku, row.note]
      end
    end
  end

  private

  def classify(variant, link, square, duplicate_skus)
    if variant.sku.blank?
      ["missing-shopify-sku", "Shopify has no SKU — Square can't match it by SKU"]
    elsif duplicate_skus.include?(variant.sku)
      ["duplicate-across-products", "Same SKU is used by another product — rename to keep one SKU per product"]
    elsif link.nil?
      ["not-linked", "No Square variation is linked to this Shopify variant"]
    elsif square.nil? || square.sku.blank?
      ["square-missing-sku", "Linked Square variation has no SKU"]
    elsif variant.sku.to_s.downcase != square.sku.to_s.downcase
      ["sku-mismatch", "Shopify and Square SKUs differ for this product"]
    else
      ["ok", "Shopify and Square share the same SKU"]
    end
  end
end