# frozen_string_literal: true

require "set"

# Deep audit of Square SKUs against the live Square API and the local mirror.
# Pure read-only — never writes to Square, Shopify, or the DB. Used by the
# ops:audit square task and available to call in a controller/report if wanted.
#
# Cross-references:
#   live Square catalog (items + variations + SKUs + inventory counts)
#   vs. the local SquareItem / SquareVariation mirror
#   vs. SkuLink linking to Shopify variants
class SquareSkuAudit
  Result = Struct.new(
    :summary, :live, :counts, :missing_sku, :not_mirrored, :stale_mirror,
    :duplicate_skus, :unlinked, :sellable_unlinked, :sellable_no_sku,
    :real_unmatched, :zero_qty_count, keyword_init: true
  )

  class << self
    def run!
      new.run
    end
  end

  def run
    live = SquareClient.catalog
    locations = SquareClient.locations
    location_ids = locations.map { |l| l["id"] }
    counts = location_ids.any? ? SquareClient.inventory_counts(location_ids, live.map { |v| v[:variationId] })[:counts] : {}

    live_by_id = live.index_by { |v| v[:variationId] }
    items = live.group_by { |v| v[:itemId] }
    live_ids = live_by_id.keys.to_set

    live_skus = Hash.new { |h, k| h[k] = [] }
    live.each { |v| live_skus[v[:sku].downcase] << v[:variationId] if v[:sku].present? }

    mirrored_variations = SquareVariation.where(tenant_id: Current.tenant_id).to_a
    mirror_var_by_id = mirrored_variations.index_by(&:id)
    mirror_ids = mirror_var_by_id.keys.to_set

    links = SkuLink.where(tenant_id: Current.tenant_id).select(&:linked?)
    linked_square_ids = links.map(&:squareVariationId).to_set

    shopify_variants = ShopifyVariant.where(tenant_id: Current.tenant_id).to_a
    live_sku_set = live_skus.keys.to_set

    missing_sku = live.reject { |v| v[:sku].present? }
    not_mirrored = live.reject { |v| mirror_ids.include?(v[:variationId]) }
    stale_mirror = mirrored_variations.reject { |v| live_ids.include?(v.id) }
    duplicate_skus = live_skus.select { |_, ids| ids.length > 1 }
    unlinked = live.reject { |v| linked_square_ids.include?(v[:variationId]) }
    sellable_unlinked = unlinked.select { |v| counts[v[:variationId]].to_i.positive? }
    sellable_no_sku = missing_sku.select { |v| counts[v[:variationId]].to_i.positive? }

    real_unmatched = shopify_variants.reject do |v|
      v.sku.blank? || v.sku.downcase == "routeins" || live_sku_set.include?(v.sku.downcase)
    end

    Result.new(
      summary: {
        live_variations: live.length,
        with_sku: live.length - missing_sku.length,
        without_sku: missing_sku.length,
        mirrored: mirrored_variations.length,
        not_mirrored: not_mirrored.length,
        stale_mirror: stale_mirror.length,
        duplicate_skus: duplicate_skus.length,
        unlinked: unlinked.length,
        sellable_unlinked: sellable_unlinked.length,
        sellable_no_sku: sellable_no_sku.length,
        real_unmatched: real_unmatched.length,
        zero_qty: live.count { |v| counts[v[:variationId]].to_i <= 0 },
      },
      live: live,
      counts: counts,
      missing_sku: missing_sku,
      not_mirrored: not_mirrored,
      stale_mirror: stale_mirror,
      duplicate_skus: duplicate_skus,
      unlinked: unlinked,
      sellable_unlinked: sellable_unlinked,
      sellable_no_sku: sellable_no_sku,
      real_unmatched: real_unmatched,
      zero_qty_count: live.count { |v| counts[v[:variationId]].to_i <= 0 },
    )
  end
end
