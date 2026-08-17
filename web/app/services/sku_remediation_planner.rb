# frozen_string_literal: true

# Plans unique SKUs for variants that currently share a SKU across different
# products. Shared SKUs break SKU-based linking between Shopify and Square and
# make the reconcile applier refuse (SafetyLocked). This only plans — applying
# requires updating Shopify and Square (plus re-linking) and is reviewed first.
class SkuRemediationPlanner
  Plan = Struct.new(:sku, :product, :variant_id, :variant_title, :current_qty, :proposed_sku, keyword_init: true)

  STOP_WORDS = %w[tier rosin live resin hash thca cbd hybrid indica sativa the and of gummies].freeze

  class << self
    # Returns a list of Plans for every tracked variant whose SKU is shared
    # with a variant of a different product.
    def plan
      plans = []
      shared_skus.each do |sku|
        variants = ShopifyVariant.joins(:product)
          .where(tracked: true)
          .where.not(sku: [nil, ""])
          .where(sku: sku)
          .order('"ShopifyProduct"."title", "ShopifyVariant"."title"')
        primary = variants.first.product.title
        variants.each do |variant|
          proposed = if variant.product.title == primary
            sku
          else
            "#{sku}-#{product_slug(variant.product.title)}"
          end
          plans << Plan.new(
            sku: sku,
            product: variant.product.title,
            variant_id: variant.id,
            variant_title: variant.title,
            current_qty: variant.inventoryQuantity,
            proposed_sku: proposed,
          )
        end
      end
      ensure_unique!(plans)
      plans
    end

    def shared_skus
      ShopifyVariant.where(tracked: true).where.not(sku: [nil, ""])
        .joins(:product)
        .group('"ShopifyVariant"."sku"', '"ShopifyVariant"."productId"')
        .having("COUNT(*) > 0")
        .count
        .keys
        .group_by(&:first)
        .select { |_, product_ids| product_ids.map(&:last).uniq.length > 1 }
        .keys
    end

    private

    # Same-product variants can collide on the proposed SKU (e.g. two "2 Grams"
    # rows in one product). Append -2, -3… so every recommendation is unique.
    def ensure_unique!(plans)
      plans.group_by(&:sku).each do |_, group|
        seen = Hash.new(0)
        group.each do |plan|
          seen[plan.proposed_sku] += 1
          plan.proposed_sku = "#{plan.proposed_sku}-#{seen[plan.proposed_sku]}" if seen[plan.proposed_sku] > 1
        end
      end
      plans
    end

    def product_slug(title)
      words = title.split(/\s+/).filter_map do |word|
        clean = word.sub(/[^a-zA-Z].*\z/, "")
        next if clean.empty?
        next if clean.match?(/[0-9]/)
        next if STOP_WORDS.include?(clean.downcase)

        clean
      end
      words.first(3).map(&:first).join.upcase[0, 3]
    end
  end
end
