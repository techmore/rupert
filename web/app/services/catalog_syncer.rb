# frozen_string_literal: true

# Port of pullShopify + the Shopify half of the seed script — mirrors the
# Shopify product catalog, variants, locations, and inventory levels into
# the database, journaling quantity changes as movements.
class CatalogSyncer
  SHOP_QUERY = <<~GRAPHQL
    query Shop {
      shop { name myshopifyDomain currencyCode }
    }
  GRAPHQL

  # Products are fetched with full cursor pagination: a bare `first: 250`
  # silently truncated catalogs beyond one page. 250/page is the GraphQL cap;
  # paginate_products walks every page so nothing is missed.
  PRODUCTS_QUERY = <<~GRAPHQL
    query Products($cursor: String) {
      products(first: 250, query: "status:active", sortKey: TITLE, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id title tags status handle publishedAt totalInventory
          featuredImage { url altText }
          variants(first: 100) {
            nodes {
              id title sku price inventoryQuantity
              inventoryItem {
                id tracked
                inventoryLevels(first: 10) {
                  nodes {
                    location { id }
                    quantities(names: ["available"]) { name quantity }
                  }
                }
              }
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
      location_nodes = fetch_locations
      sync_locations!(location_nodes)
      assign_shopify_primary!(location_nodes)

      # Shopify levels mirror PER LOCATION now (same as Square): keyed by the
      # Location record id, quantity = that location's "available" count.
      # The variant's inventoryQuantity total is still stored on ShopifyVariant.
      locations_by_gid = Location.by_source("shopify")
        .index_by(&:externalId)
      primary = Location.shopify_primary ||
        Location.find_by(source: "shopify", externalId: "default")

      counts = sync_products!(paginate_products, locations_by_gid, primary)
      {
        products: counts[:products],
        variants: counts[:variants],
        locations: location_nodes,
        orders: paginate_orders(since),
        shop: ShopifyClient.graphql(SHOP_QUERY, {})["shop"],
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

    # Fetches every ACTIVE product, following the cursor until exhausted.
    # Returns the flat array of product nodes for sync_products!.
    def paginate_products
      nodes = []
      cursor = nil
      loop do
        data = ShopifyClient.graphql(PRODUCTS_QUERY, { cursor: cursor })
        page = data["products"]
        nodes.concat(page["nodes"] || [])
        info = page["pageInfo"] || {}
        break unless info["hasNextPage"] && info["endCursor"]

        cursor = info["endCursor"]
      end
      nodes
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

    # Flags exactly one Shopify location as primary: SHOPIFY_LOCATION_ID if set,
    # else the first ACTIVE location in the API's order (the online store is
    # usually first), else the first known row. Deterministic — the previous
    # "oldest syncedAt wins" pick broke once more than one location existed.
    def assign_shopify_primary!(location_nodes)
      preferred_gid = EnvStore.fetch("SHOPIFY_LOCATION_ID", "").presence
      gids = location_nodes.map { |node| node["id"] }
      active_gids = location_nodes.select { |node| node["isActive"] != false }.map { |node| node["id"] }
      chosen_gid =
        (preferred_gid if gids.include?(preferred_gid)) ||
        active_gids.first ||
        gids.first

      chosen = chosen_gid.present? ? Location.find_by(source: "shopify", externalId: chosen_gid) : nil
      return if chosen.nil?

      Location.by_source("shopify").where(primary_location: true).where.not(id: chosen.id)
        .update_all(primary_location: false) # rubocop:disable Rails/SkipsModelValidations
      chosen.update_column(:primary_location, true) unless chosen.primary_location? # rubocop:disable Rails/SkipsModelValidations
      chosen
    end

    def sync_products!(products, locations_by_gid, primary)
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
            tags: Array(product["tags"]).join(", "),
            syncedAt: Time.current,
          },
          unique_by: :id,
        )

        Array(product.dig("variants", "nodes")).each do |variant|
          sync_variant!(product["id"], variant, locations_by_gid, primary)
          variant_count += 1
        end
      end

      prune_stale_shopify_levels!
      { products: products.length, variants: variant_count }
    end

    def sync_variant!(product_id, variant, locations_by_gid, primary)
      # Mirrored inventory stays non-negative: oversold Shopify counts are
      # zeroed locally (the negative-inventory remediation) instead of being
      # pushed back to Shopify. Reconcile therefore sees 0 for these SKUs.
      quantity = [variant["inventoryQuantity"].to_i, 0].max
      item = variant["inventoryItem"] || {}

      attrs = {
        id: variant["id"],
        productId: product_id,
        title: variant["title"],
        sku: variant["sku"],
        price: variant["price"]&.to_f,
        inventoryQuantity: quantity,
        tracked: item["tracked"] == true,
        inventoryItemId: item["id"],
        syncedAt: Time.current,
      }
      ShopifyVariant.upsert(attrs, unique_by: :id)

      # One mirrored level PER Shopify location (like the Square side), keyed by
      # the Location record id so level.location resolves and per-location stock
      # is answerable. Aggregated readers (totals, dashboards, PDF) sum across
      # rows, so their numbers are unchanged.
      level_nodes = Array(item.dig("inventoryLevels", "nodes"))
      if level_nodes.empty?
        # Untracked items / shapes without level data: keep the variant total on
        # the primary row so the item still surfaces in views and alerts.
        write_shopify_level!(primary&.id, variant["id"], variant["sku"], quantity) if primary
      else
        level_nodes.each do |node|
          location = locations_by_gid[node.dig("location", "id")]
          next if location.nil?

          available = Array(node["quantities"]).find { |q| q["name"] == "available" }&.dig("quantity").to_i
          write_shopify_level!(location.id, variant["id"], variant["sku"], [available, 0].max)
        end
      end

      AlertGenerator.sync_variant!(variant["id"], variant["sku"], quantity)
    end

    def write_shopify_level!(location_id, variant_id, sku, quantity)
      return if location_id.nil?

      level = InventoryLevel.find_or_initialize_by(
        source: "shopify", locationId: location_id, shopifyVariantId: variant_id,
      )
      journal_movement(
        level,
        variant_id,
        quantity,
        source: "shopify",
        reference: "sync",
        sku: sku,
      )
      level.quantity = quantity
      level.available = quantity
      level.updatedAt = Time.current
      level.save!
    end

    # Deletes mirrored Shopify levels whose location no longer exists (a
    # location was deactivated/removed on Shopify). Guarded: if NO shopify
    # locations are known — e.g. a transient API failure earlier in the run —
    # nothing is deleted. Stale rows are dropped without journaling; they were
    # mirror bookkeeping for a location that no longer exists, not real stock.
    def prune_stale_shopify_levels!
      known_ids = Location.by_source("shopify").pluck(:id)
      return 0 if known_ids.empty?

      removed = InventoryLevel.mirrored("shopify").where.not(locationId: known_ids).delete_all
      Rails.logger.info("CatalogSyncer: pruned #{removed} stale Shopify inventory level rows") if removed.positive?
      removed
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
        syncRunId: Current.sync_run_id,
        createdAt: Time.current,
      )
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value) : nil
    end
  end
end
