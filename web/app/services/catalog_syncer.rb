# frozen_string_literal: true

# Port of pullShopify + the Shopify half of the seed script — mirrors the
# Shopify product catalog, variants, locations, and inventory levels into
# the database, journaling quantity changes as movements.
class CatalogSyncer
  OPERATIONS_QUERY = <<~GRAPHQL
    query Ops($orderQuery: String!) {
      shop { name myshopifyDomain currencyCode }
      publications(first: 30) { nodes { id name autoPublish } }
      products(first: 250, query: "status:active", sortKey: TITLE) {
        nodes {
          id title status handle publishedAt totalInventory
          resourcePublicationsCount { count }
          resourcePublications(first: 20) { nodes { isPublished publishDate publication { id name } } }
          variants(first: 100) { nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } }
        }
      }
      orders(first: 100, query: $orderQuery, sortKey: CREATED_AT, reverse: true) {
        pageInfo { hasNextPage }
        nodes {
          id name createdAt displayFinancialStatus
          currentTotalPriceSet { shopMoney { amount currencyCode } }
          lineItems(first: 100) { nodes { title variantTitle sku quantity } }
        }
      }
    }
  GRAPHQL

  LOCATIONS_QUERY = <<~GRAPHQL
    query Locations { locations(first: 10) { nodes { id name isActive } } }
  GRAPHQL

  THRESHOLD = 5

  class << self
    # Returns { products:, variants:, locations:, orders:, shop: }
    def sync!
      since = (Time.current - 30.days).strftime("%Y-%m-%d")
      data = ShopifyClient.graphql(OPERATIONS_QUERY, { orderQuery: "created_at:>=#{since}" })

      locations = fetch_locations
      sync_locations!(locations)
      counts = sync_products!(data["products"]["nodes"], locations)
      { products: counts[:products], variants: counts[:variants],
        locations: locations, orders: data["orders"], shop: data["shop"] }
    end

    private

    def fetch_locations
      ShopifyClient.graphql(LOCATIONS_QUERY, {})["locations"]["nodes"]
    rescue StandardError
      []
    end

    def sync_locations!(nodes)
      if nodes.empty?
        upsert_location(source: "shopify", external_id: "default", name: "Shopify Online Store", kind: "VIRTUAL")
      else
        nodes.each do |location|
          upsert_location(
            source: "shopify", external_id: location["id"], name: location["name"],
            kind: "RETAIL", active: location["isActive"] != false
          )
        end
      end
    end

    def upsert_location(source:, external_id:, name:, kind: nil, active: true)
      record = Location.find_or_initialize_by(source: source, externalId: external_id)
      record.name = name
      record.kind = kind if kind
      record.active = active
      record.syncedAt = Time.current
      record.save!
      record
    end

    def sync_products!(products, locations)
      primary = locations.first || Location.find_by(source: "shopify", externalId: "default")
      variant_count = 0

      products.each do |product|
        ShopifyProduct.upsert({
          id: product["id"], title: product["title"], status: product["status"],
          handle: product["handle"], publishedAt: parse_time(product["publishedAt"]),
          totalInventory: product["totalInventory"].to_i, syncedAt: Time.current
        }, unique_by: :id)

        Array(product.dig("variants", "nodes")).each do |variant|
          sync_variant!(product["id"], variant, primary)
          variant_count += 1
        end
      end

      { products: products.length, variants: variant_count }
    end

    def sync_variant!(product_id, variant, location)
      attrs = {
        id: variant["id"], productId: product_id, title: variant["title"], sku: variant["sku"],
        price: variant["price"].nil? ? nil : variant["price"].to_f,
        inventoryQuantity: variant["inventoryQuantity"].to_i,
        tracked: variant.dig("inventoryItem", "tracked") == true,
        inventoryItemId: variant.dig("inventoryItem", "id"),
        syncedAt: Time.current
      }
      ShopifyVariant.upsert(attrs, unique_by: :id)

      return unless location

      quantity = attrs[:inventoryQuantity]
      level = InventoryLevel.find_or_initialize_by(
        source: "shopify", locationId: location.id, shopifyVariantId: variant["id"]
      )
      journal_movement(level, variant["id"], quantity, source: "shopify",
        reference: "sync", sku: variant["sku"])
      level.quantity = quantity
      level.available = quantity
      level.updatedAt = Time.current
      level.save!

      AlertGenerator.sync_variant!(variant["id"], variant["sku"], quantity)
    end

    def journal_movement(level, variant_id, new_quantity, source:, reference:, sku:)
      before = level.quantity || 0
      return if before == new_quantity

      InventoryMovement.create!(
        sku: sku, shopifyVariantId: variant_id, source: source, direction: "set",
        delta: new_quantity - before, quantityBefore: before, quantityAfter: new_quantity,
        reason: "Synced from Shopify", reference: reference, actor: "system",
        createdAt: Time.current
      )
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    end
  end
end
