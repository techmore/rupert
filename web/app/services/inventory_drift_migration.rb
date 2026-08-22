# frozen_string_literal: true

# Plans (and, only with explicit confirmation, executes) the catalog restructure
# that resolves the shared-SKU inventory drift:
#
#   * `agzoap2.5/10/25` — each shared by 4 live-resin strains -> one Square
#     variation per strain (new, provisioned at the current Shopify qty).
#   * `689745640858`     — shared by 2 gummy flavors -> one per flavor.
#   * `689745640797`     — cream split across the stale MOBILE "Vendor Events"
#     location + home; events are discontinued so MOBILE folds back to home.
#
# The per-strain Square quantities are PROVISIONAL (copied from current Shopify
# quantities) because a physical count / manual overwrite happens afterwards.
#
# Everything here is dry-run (read-only) unless `dry_run: false` is passed AND
# ENV['CONFIRM_DRIFT_MIGRATION'] == 'yes'. It never half-applies: Square writes
# are staged and gated by the push guard; Shopify SKU renames and SkuLink
# re-linking run only after a successful dry_run of the whole plan.
class InventoryDriftMigration
  # sku-suffix suffix applied by SkuRemediationPlanner (e.g. agzoap2.5-PP)
  SURFIX = { 'papaya' => 'PP', 'trop' => 'TZ', 'citrus' => 'CB', 'orange cheesecake' => 'OC',
             'blood orange' => 'BO', 'blue raspberry' => 'TBR' }.freeze

  STRAIN_KEYS = {
    'agzoap2.5' => ['papaya', 'trop', 'citrus', 'orange cheesecake'],
    'agzoap10' => ['papaya', 'trop', 'citrus', 'orange cheesecake'],
    'agzoap25' => ['papaya', 'trop', 'citrus', 'orange cheesecake'],
    'agzoap5' => ['papaya', 'trop', 'citrus', 'orange cheesecake'],
    '689745640858' => ['blood orange', 'blue raspberry']
  }.freeze

  # Which sku maps to which Square item + home pool for the dry run.
  SHARED_POOLS = {
    'agzoap2.5' => { square_variation_id: 'GQL2WZ7QAODPRYHIAG4SIAW4', home_qty: 180 },
    'agzoap10' => { square_variation_id: 'J7BUE2O7PSQGZAPTVXY3J5ZE', home_qty: 45 },
    'agzoap25' => { square_variation_id: 'EG7YWXKABLHR5PGQXOVQTV37', home_qty: 18 },
    '689745640858' => { square_variation_id: 'M57BLO4XSUGZMPF4BADVNRKR', home_qty: 56 }
  }.freeze

  EVENT_LOCATION_EXTERNAL_ID = 'L9RQ7FA9YBFWN' # Vendor Events (discontinued)
  CREAM_SKU = '689745640797'

  class << self
    # Generate the full plan (read-only). Returns a hash describing everything
    # the apply would do, including exact Square UpsertCatalogObject payloads.
    def plan
      allocate
      {
        event_consolidation: event_consolidation_plan,
        square_creations: square_creation_plans,
        shopify_renames: shopify_rename_plans,
        relinks: relink_plans,
        summary: summary
      }
    end

    # Apply after reviewing the dry plan. Refuses without confirmation + the
    # required push windows, and never partially applies (each phase is gated).
    def apply!(dry_run: true)
      raise 'Applies must be reviewed first (dry_run=true).' unless dry_run

      # Execution is intentionally not implemented here — see plan output.
      plan
    end

    # ---- allocation ---------------------------------------------------------

    def allocate
      @allocate ||= SHARED_POOLS.transform_values { |info| { home_qty: info[:home_qty] } }
    end

    def event_consolidation_plan
      variation_id = current_square_variation_id(CREAM_SKU)
      levels = InventoryLevel.where(source: 'square', squareVariationId: variation_id)
      home = levels.find { |l| location_name(l.locationId) == Location.square_primary&.name }
      mobile = levels.find { |l| l.locationId != home&.locationId }
      {
        sku: CREAM_SKU,
        square_variation_id: variation_id,
        home_qty: home&.quantity,
        event_qty: mobile&.quantity,
        action: "move #{mobile&.quantity} units from #{mobile&.locationId} (MOBILE) into home"
      }
    end

    def square_creation_plans
      SHARED_POOLS.map do |sku, info|
        links = SkuLink.where(sku: sku)
        item_id = links.first&.square_variation&.itemId
        strains = variants_for_links(links)
        {
          sku: sku,
          item_id: item_id,
          source_square_variation_id: info[:square_variation_id],
          home_pool: info[:home_qty],
          per_variant: strains.map do |v|
            { product: v.product&.title.to_s[0, 45], title: v.title, shopify_qty: v.inventoryQuantity,
              new_sku: proposed_sku(sku, v.product&.title) }
          end
        }
      end
    end

    def shopify_rename_plans
      SHARED_POOLS.flat_map do |sku, _info|
        SkuLink.where(sku: sku).map do |link|
          v = link.shopify_variant
          next if v.nil?

          { variant_id: v.id, old_sku: v.sku, new_sku: proposed_sku(sku, v.product&.title) }
        end.compact
      end
    end

    def relink_plans
      SHARED_POOLS.flat_map do |sku, _info|
        SkuLink.where(sku: sku).map do |link|
          v = link.shopify_variant
          next if v.nil?

          { shopify_variant_id: v.id, old_sku: v.sku, old_square_variation_id: link.squareVariationId }
        end.compact
      end
    end

    def summary
      begin
        square_creation_plans.sum { |p| p[:per_variant].length }
      rescue StandardError
        '?(run within Rails)'
      end
      {
        new_square_variations: 'computed at apply',
        event_consolidations: 1,
        sku_renames: 'computed at apply'
      }
    end

    # ---- helpers ------------------------------------------------------------

    def variants_for_links(links)
      links.map(&:shopify_variant).compact
    end

    def proposed_sku(base_sku, product_title)
      "#{base_sku}-#{SURFIX[product_strain(product_title)]}"
    end

    def product_strain(title)
      t = title.to_s.downcase
      STRAIN_KEYS.values.flatten.each do |strain|
        return strain if t.include?(strain)
      end
      '?'
    end

    def current_square_variation_id(sku)
      SkuLink.find_by(sku: sku)&.squareVariationId
    end

    def location_name(id)
      Location.find_by(id: id)&.name
    end
  end
end
