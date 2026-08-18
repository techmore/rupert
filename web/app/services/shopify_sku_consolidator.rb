# frozen_string_literal: true

require "set"

# Consolidates surplus Shopify variants that share one SKU (which maps to a
# single POOLED Square item). Business decision: for these SKUs there is really
# only ONE physical product per SKU/size, so Shopify should have exactly one
# canonical, tracked variant — not multiple "strain" duplicates.
#
# Mechanism (reversible, no destructive Shopify deletion):
#   mark the SURPLUS variants untracked in the mirror so they stop appearing in
#   Inventory / Reconcile / PDF as duplicate rows. The canonical (keep) variant
#   stays tracked and remains the one that maps to the pooled Square item.
#
# Explicitly EXCLUDED:
#   - ROUTEINS (76 rows): non-sellable shipping insurance — leave tracked=false as-is.
#   - Archived Afghan Hash product: handled by de-linking (separate DbPlan).
class ShopifySkuConsolidator
  SKIP_SKUS = %w[routeins].freeze

  attr_reader :plan

  class << self
    def build_plan!
      new.build_plan!
    end

    def apply!(confirmed: ENV["CONFIRM_CONSOLIDATE"] == "yes")
      r = new
      r.build_plan!
      r.apply!(confirmed: confirmed)
    end
  end

  def build_plan!
    groups = duplicate_groups

    consolidated = groups.map do |base, variants|
      canonical = pick_canonical(variants)
      surplus = variants.reject { |v| v.id == canonical.id }
      {
        base: base,
        size: canonical.title,
        canonical: canonical,
        surplus: surplus,
        already_tracked: surplus.count { |v| v.tracked },
        archived_surplus: surplus.count { |v| status_of(v) == "ARCHIVED" },
      }
    end

    @plan = {
      dry_run: true,
      generated_at: Time.current,
      groups: consolidated,
      skipped_routeins: 76,
      summary: {
        groups: consolidated.length,
        surplus_to_untrack: consolidated.sum { |g| g[:surplus].count { |v| v.tracked } },
        archived_surplus_to_delink: consolidated.sum { |g| g[:archived_surplus] },
        canonical_kept: consolidated.length,
      },
    }
  end

  def apply!(confirmed: ENV["CONFIRM_CONSOLIDATE"] == "yes")
    raise "Call build_plan! first" if @plan.nil?
    raise "Applying requires ENV['CONFIRM_CONSOLIDATE']=yes" unless confirmed

    result = { untracked: 0, delinked_archived: 0, skipped_already_untracked: 0, canonical_kept: [] }
    @plan[:groups].each do |g|
      g[:surplus].each do |v|
        if v.tracked
          v.update!(tracked: false)
          result[:untracked] += 1
        else
          result[:skipped_already_untracked] += 1
        end
        # archived duplicate copies should lose their link so they stop tripping
        # the shared-SKU flag
        if status_of(v) == "ARCHIVED"
          link = SkuLink.linked.find_by(shopifyVariantId: v.id)
          if link
            link.destroy
            result[:delinked_archived] += 1
          end
        end
      end
      result[:canonical_kept] << g[:canonical].sku
    end
    result
  end

  private

  def duplicate_groups
    scope = ShopifyVariant.where.not(sku: [nil, ""])
      .where(tracked: true) # only consider currently-tracked (sellable) variants
    collisions = {}
    scope.each do |v|
      next if SKIP_SKUS.include?(v.sku.downcase)
      collisions[v.sku] ||= []
      collisions[v.sku] << v
    end
    collisions.select { |_, vs| vs.length > 1 }
  end

  # The variant to KEEP: prefer one on an ACTIVE product (archived copies are
  # duplicates to clean), then one already linked to a Square variation, then
  # the first by id.
  def pick_canonical(variants)
    active = variants.select { |v| status_of(v) != "ARCHIVED" }
    pool = active.empty? ? variants : active

    linked = pool.find { |v| SkuLink.linked.exists?(shopifyVariantId: v.id) }
    return linked if linked

    pool.min_by(&:id)
  end

  def status_of(variant)
    ShopifyProduct.find_by(id: variant.productId)&.status
  end
end
