# frozen_string_literal: true

# Port of pullSquare + the Square half of the seed script — mirrors the
# Square catalog, locations, inventory counts, and SKU links into the
# database, journaling quantity changes as movements.
class SquareSyncer
  class << self
    # Returns { items:, variations:, levels:, links:, orders:, locations: }
    def sync!(since: nil)
      locations = SquareClient.locations
      primary = pick_primary_location(locations)
      raise SquareClient::Error, "Square: no active location found" if primary.nil?

      catalog = SquareClient.catalog
      counts = SquareClient.inventory_counts(locations.map { |l| l["id"] }, catalog.map { |v| v[:variationId] })
      orders = SquareClient.orders(
        locations.map { |l| l["id"] },
        since || (Time.current - history_lookback).iso8601,
      )

      sync_locations!(locations, catalog, counts, primary)
      { items: 0, variations: 0, levels: 0, links: 0, orders: orders, locations: locations }
    end

    # How far back to look for orders. Configurable via SYNC_HISTORY_DAYS
    # (defaults to 30 days to match the original behavior).
    def history_lookback
      days = EnvStore.fetch("SYNC_HISTORY_DAYS", "").to_i
      days.positive? ? days.days : 30.days
    end

    def primary_location_id
      preferred = EnvStore.fetch("SQUARE_LOCATION_ID", "")
      location = preferred.present? ? Location.find_by(source: "square", externalId: preferred) : nil
      location || Location.square_primary
    end

    private

    def pick_primary_location(locations)
      preferred = EnvStore.fetch("SQUARE_LOCATION_ID", "")
      locations.find { |l| l["id"] == preferred } || locations.first
    end

    def sync_locations!(locations, catalog, counts, primary)
      sync_catalog!(catalog)
      sync_links!(catalog)
      sync_levels!(locations, catalog, counts, primary)
    end

    def sync_catalog!(catalog)
      catalog.group_by { |v| v[:itemId] }.each do |item_id, variations|
        SquareItem.upsert({ id: item_id, name: variations.first[:name], syncedAt: Time.current }, unique_by: :id)
        variations.each do |variation|
          SquareVariation.upsert(
            {
              id: variation[:variationId],
              itemId: item_id,
              sku: variation[:sku],
              name: variation[:name],
              syncedAt: Time.current,
            },
            unique_by: :id,
          )
        end
      end
    end

    def sync_links!(catalog)
      by_sku = {}
      catalog.each { |v| by_sku[v[:sku].downcase] = v[:variationId] if v[:sku].present? }
      links = 0
      ShopifyVariant.where.not(sku: [nil, ""]).find_each do |variant|
        square_id = by_sku[variant.sku.downcase]
        next if square_id.nil?

        link = SkuLink.find_or_initialize_by(shopifyVariantId: variant.id)
        links += 1
        if link.persisted? && link.sku == variant.sku && link.squareVariationId == square_id &&
            link.matchSource == "sku" && link.auto
          next
        end
        link.sku = variant.sku
        link.squareVariationId = square_id
        link.matchSource = "sku"
        link.auto = true
        link.createdAt ||= Time.current
        link.save!
      end
      links
    end

    def sync_levels!(locations, catalog, counts, primary)
      location_records = locations.map do |location|
        upsert_location(
          source: "square",
          external_id: location["id"],
          name: location["name"],
          kind: location["type"],
          timezone: location["timezone"],
        )
      end
      location_records.find { |l| l.externalId == primary["id"] } || location_records.first

      location_records.each do |location_record|
        by_variation = counts[:counts_by_location][location_record.externalId] || Hash.new(0)
        catalog.each do |variation|
          quantity = by_variation[variation[:variationId]]
          next if quantity.nil?

          level = InventoryLevel.find_or_initialize_by(
            source: "square", locationId: location_record.id, squareVariationId: variation[:variationId],
          )
          before = level.quantity || 0
          if before != quantity
            InventoryMovement.create!(
              sku: variation[:sku],
              squareVariationId: variation[:variationId],
              source: "square",
              direction: "set",
              delta: quantity - before,
              quantityBefore: before,
              quantityAfter: quantity,
              reason: "Synced from Square",
              reference: "sync",
              actor: "system",
              syncRunId: Current.sync_run_id,
              createdAt: Time.current,
            )
          end
          level.quantity = quantity
          level.available = quantity
          if level.new_record? || level.changed?
            level.updatedAt = Time.current
            level.save!
          end
        end
      end
    end

    def upsert_location(source:, external_id:, name:, kind: nil, timezone: nil)
      record = Location.find_or_initialize_by(source: source, externalId: external_id)
      record.name = name
      record.kind = kind if kind
      record.timezone = timezone if timezone
      record.active = true
      record.syncedAt = Time.current
      record.save!
      record
    end
  end
end
