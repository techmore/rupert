# frozen_string_literal: true

# Port of pullSquare + the Square half of the seed script — mirrors the
# Square catalog, locations, inventory counts, and SKU links into the
# database, journaling quantity changes as movements.
class SquareSyncer
  class << self
    include SyncConcern

    # Returns { items:, variations:, levels:, links:, orders:, locations: }
    def sync!(since: nil)
      locations = SquareClient.locations
      primary = pick_primary_location(locations)
      raise SquareClient::Error, 'Square: no active location found' if primary.nil?

      catalog = SquareClient.catalog
      counts = SquareClient.inventory_counts(locations.map { |l| l['id'] }, catalog.map { |v| v[:variationId] })
      orders = SquareClient.orders(
        locations.map { |l| l['id'] },
        since || (Time.current - history_lookback).iso8601
      )

      sync_locations!(locations, catalog, counts, primary)
      { items: 0, variations: 0, levels: 0, links: 0, orders: orders, locations: locations }
    end

    def primary_location_id
      preferred = EnvStore.fetch('SQUARE_LOCATION_ID', '')
      location = preferred.present? ? Location.find_by(source: 'square', externalId: preferred) : nil
      location || Location.square_primary
    end

    private

    def pick_primary_location(locations)
      preferred = EnvStore.fetch('SQUARE_LOCATION_ID', '')
      locations.find { |l| l['id'] == preferred } || locations.first
    end

    def sync_locations!(locations, catalog, counts, primary)
      sync_catalog!(catalog)
      sync_links!(catalog)
      sync_levels!(locations, catalog, counts, primary)
    end

    def sync_catalog!(catalog)
      now = Time.current
      item_rows = {}
      variation_rows = []
      catalog.each do |variation|
        # Bulk writes skip callbacks, so rows carry tenant_id explicitly.
        item_rows[variation[:itemId]] ||= {
          id: variation[:itemId], name: variation[:name], syncedAt: now, tenant_id: Current.tenant_id
        }
        variation_rows << {
          id: variation[:variationId], itemId: variation[:itemId], sku: variation[:sku],
          name: variation[:name], syncedAt: now, tenant_id: Current.tenant_id
        }
      end

      SquareItem.upsert_all(item_rows.values, unique_by: :id) if item_rows.any?
      SquareVariation.upsert_all(variation_rows, unique_by: :id) if variation_rows.any?
    end

    def sync_links!(catalog)
      by_sku = {}
      catalog.each { |v| by_sku[v[:sku].downcase] = v[:variationId] if v[:sku].present? }
      existing_links = SkuLink.all.index_by(&:shopifyVariantId)
      links = 0
      ShopifyVariant.where.not(sku: [nil, '']).includes(:product).find_each do |variant|
        # Wholesale/bulk Shopify-only products never link to Square (they're not
        # carried there) — the wholesale tag on the product excludes them.
        next if variant.product&.tags.to_s.split(',').map(&:strip).include?('wholesale')

        square_id = by_sku[variant.sku.downcase]
        next if square_id.nil?

        link = existing_links[variant.id]
        links += 1
        if link && link.sku == variant.sku && link.squareVariationId == square_id &&
           link.matchSource == 'sku' && link.auto
          next
        end

        link ||= SkuLink.new(shopifyVariantId: variant.id)
        link.sku = variant.sku
        link.squareVariationId = square_id
        link.matchSource = 'sku'
        link.auto = true
        link.createdAt ||= Time.current
        link.save!
      end
      links
    end

    def sync_levels!(locations, catalog, counts, _primary)
      now = Time.current
      location_records = locations.map do |location|
        upsert_location(
          source: 'square',
          external_id: location['id'],
          name: location['name'],
          kind: location['type'],
          timezone: location['timezone']
        )
      end

      # Desired per-location rows, diffed against existing levels loaded once,
      # then written as one upsert + one movement insert (same shape as the
      # Shopify side).
      desired = []
      location_records.each do |location_record|
        by_variation = counts[:counts_by_location][location_record.externalId] || Hash.new(0)
        catalog.each do |variation|
          quantity = by_variation[variation[:variationId]]
          next if quantity.nil?

          desired << {
            location_id: location_record.id,
            variation_id: variation[:variationId],
            sku: variation[:sku],
            quantity: quantity
          }
        end
      end
      return if desired.empty?

      existing = InventoryLevel.mirrored('square')
                               .where(squareVariationId: desired.map { |d| d[:variation_id] })
                               .index_by do |level|
        [level.locationId,
         level.squareVariationId]
      end

      level_rows = desired.map do |d|
        old = existing[[d[:location_id], d[:variation_id]]]
        {
          id: old&.id || HasCuid.generate,
          source: 'square',
          locationId: d[:location_id],
          squareVariationId: d[:variation_id],
          quantity: d[:quantity],
          available: d[:quantity],
          updatedAt: now,
          tenant_id: Current.tenant_id
        }
      end

      movement_rows = desired.filter_map do |d|
        before = existing[[d[:location_id], d[:variation_id]]]&.quantity || 0
        next if before == d[:quantity]

        {
          id: HasCuid.generate,
          sku: d[:sku],
          squareVariationId: d[:variation_id],
          source: 'square',
          direction: 'set',
          delta: d[:quantity] - before,
          quantityBefore: before,
          quantityAfter: d[:quantity],
          reason: 'Synced from Square',
          reference: 'sync',
          actor: 'system',
          syncRunId: Current.sync_run_id,
          createdAt: now,
          tenant_id: Current.tenant_id
        }
      end

      ActiveRecord::Base.transaction do
        InventoryLevel.upsert_all(level_rows, unique_by: :idx_inventory_levels_tenant_source_loc_square)
        InventoryMovement.insert_all(movement_rows) if movement_rows.any?
      end
    end
  end
end
