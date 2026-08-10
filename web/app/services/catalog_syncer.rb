# frozen_string_literal: true

# Port of pullShopify + the Shopify half of the seed script — mirrors the
# Shopify product catalog, variants, locations, and inventory levels into
# the database, journaling quantity changes as movements.
class CatalogSyncer
  OPERATIONS_QUERY = <<~GRAPHQL
    query Ops($orderQuery: String!, $orderCursor: String) {
      shop { name myshopifyDomain currencyCode }
      publications(first: 30) { nodes { id name autoPublish } }
      products(first: 250, query: "status:active", sortKey: TITLE) {
        nodes {
          id title status handle publishedAt totalInventory
          featuredImage { url altText }
          resourcePublicationsCount { count }
          resourcePublications(first: 20) { nodes { isPublished publishDate publication { id name } } }
          variants(first: 100) { nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } }
        }
      }
      orders(first: 100, query: $orderQuery, sortKey: CREATED_AT, reverse: true, after: $orderCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id name createdAt displayFinancialStatus paymentGatewayNames
          currentTotalPriceSet { shopMoney { amount currencyCode } }
          currentTotalTaxSet { shopMoney { amount currencyCode } }
          customer { id email firstName lastName phone }
          shippingAddress {
            address1 address2 city country province zip phone
          }
          fulfillments {
            id status createdAt updatedAt
            trackingInfo { company number url }
          }
          lineItems(first: 100) {
            nodes {
              title variantTitle sku quantity
              originalUnitPriceSet { shopMoney { amount currencyCode } }
              originalTotalSet { shopMoney { amount currencyCode } }
            }
          }
        }
      }
    }
  GRAPHQL

  LOCATIONS_QUERY = <<~GRAPHQL
    query Locations { locations(first: 10) { nodes { id name isActive } } }
  GRAPHQL

  # Paginates every order matching the query, so the sync captures the full
  # history window rather than the first page.
  ORDERS_QUERY = <<~GRAPHQL
    query Orders($orderQuery: String!, $orderCursor: String) {
      orders(first: 100, query: $orderQuery, sortKey: CREATED_AT, reverse: true, after: $orderCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id name createdAt displayFinancialStatus paymentGatewayNames
          currentTotalPriceSet { shopMoney { amount currencyCode } }
          currentTotalTaxSet { shopMoney { amount currencyCode } }
          customer { id email firstName lastName phone }
          shippingAddress {
            address1 address2 city country province zip phone
          }
          fulfillments {
            id status createdAt updatedAt
            trackingInfo { company number url }
          }
          lineItems(first: 100) {
            nodes {
              title variantTitle sku quantity
              originalUnitPriceSet { shopMoney { amount currencyCode } }
              originalTotalSet { shopMoney { amount currencyCode } }
            }
          }
        }
      }
    }
  GRAPHQL

  # Minimal query to backfill featured images without re-pulling the whole
  # catalog. `first: 250` per page; cursor pagination for large catalogs.
  IMAGE_BACKFILL_QUERY = <<~GRAPHQL
    query Images($cursor: String) {
      products(first: 250, query: "status:active", sortKey: TITLE, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id featuredImage { url } }
      }
    }
  GRAPHQL

  THRESHOLD = 5

  class << self
    # Returns { products:, variants:, locations:, orders:, shop: }
    def sync!(since: nil)
      since ||= (Time.current - history_lookback).strftime("%Y-%m-%d")
      locations = fetch_locations
      sync_locations!(locations)
      data = ShopifyClient.graphql(OPERATIONS_QUERY, { orderQuery: "created_at:>=#{since}" })
      counts = sync_products!(data["products"]["nodes"], locations)
      {
        products: counts[:products],
        variants: counts[:variants],
        locations: locations,
        orders: paginate_orders(since),
        shop: data["shop"],
      }
    end

    # Backfill featuredImageUrl for every active product (used when images
    # were added after a catalog was already mirrored). Returns rows updated.
    def backfill_images!
      count = 0
      cursor = nil
      loop do
        data = ShopifyClient.graphql(IMAGE_BACKFILL_QUERY, { cursor: cursor })
        nodes = data.dig("products", "nodes") || []
        nodes.each do |node|
          url = node.dig("featuredImage", "url")
          next if url.blank?

          updated = ShopifyProduct.where(id: node["id"]).update_all(featuredImageUrl: url)
          count += updated
        end
        page = data.dig("products", "pageInfo") || {}
        break unless page["hasNextPage"] && page["endCursor"]

        cursor = page["endCursor"]
      end
      count
    end

    private

    # How far back to look for orders. Configurable via the SYNC_HISTORY_DAYS
    # setting (defaults to 30 days to match the original behavior).
    def history_lookback
      days = EnvStore.fetch("SYNC_HISTORY_DAYS", "").to_i
      days.positive? ? days.days : 30.days
    end

    # Fetches every order in the window, following the cursor until exhausted.
    # Returns the raw GraphQL "orders" object ({ nodes:, pageInfo: }).
    def paginate_orders(since)
      nodes = []
      cursor = nil
      loop do
        data = ShopifyClient.graphql(ORDERS_QUERY, { orderQuery: "created_at:>=#{since}", orderCursor: cursor })
        page = data["orders"]
        nodes.concat(page["nodes"] || [])
        info = page["pageInfo"] || {}
        break unless info["hasNextPage"] && info["endCursor"]

        cursor = info["endCursor"]
      end
      { "nodes" => nodes, "pageInfo" => { "hasNextPage" => false, "endCursor" => cursor } }
    end

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
            source: "shopify",
            external_id: location["id"],
            name: location["name"],
            kind: "RETAIL",
            active: location["isActive"] != false,
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
        ShopifyProduct.upsert(
          {
            id: product["id"],
            title: product["title"],
            status: product["status"],
            handle: product["handle"],
            publishedAt: parse_time(product["publishedAt"]),
            totalInventory: product["totalInventory"].to_i,
            featuredImageUrl: product.dig("featuredImage", "url"),
            syncedAt: Time.current,
          },
          unique_by: :id,
        )

        Array(product.dig("variants", "nodes")).each do |variant|
          sync_variant!(product["id"], variant, primary)
          variant_count += 1
        end
      end

      { products: products.length, variants: variant_count }
    end

    def sync_variant!(product_id, variant, location)
      attrs = {
        id: variant["id"],
        productId: product_id,
        title: variant["title"],
        sku: variant["sku"],
        price: variant["price"]&.to_f,
        inventoryQuantity: variant["inventoryQuantity"].to_i,
        tracked: variant.dig("inventoryItem", "tracked") == true,
        inventoryItemId: variant.dig("inventoryItem", "id"),
        syncedAt: Time.current,
      }
      ShopifyVariant.upsert(attrs, unique_by: :id)

      return unless location

      quantity = attrs[:inventoryQuantity]
      level = InventoryLevel.find_or_initialize_by(
        source: "shopify", locationId: location["id"], shopifyVariantId: variant["id"],
      )
      journal_movement(
        level,
        variant["id"],
        quantity,
        source: "shopify",
        reference: "sync",
        sku: variant["sku"],
      )
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
        sku: sku,
        shopifyVariantId: variant_id,
        source: source,
        direction: "set",
        delta: new_quantity - before,
        quantityBefore: before,
        quantityAfter: new_quantity,
        reason: "Synced from Shopify",
        reference: reference,
        actor: "system",
        createdAt: Time.current,
      )
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    end
  end
end
