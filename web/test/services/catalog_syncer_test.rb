# frozen_string_literal: true

require "test_helper"

class CatalogSyncerTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    EnvStore::MANAGED_KEYS.freeze unless EnvStore::MANAGED_KEYS.frozen?
  end

  teardown do
    Setting.where(key: "SYNC_HISTORY_DAYS").delete_all
    Current.tenant = nil
  end

  test "history_lookback defaults to 30 days when unset" do
    assert_equal 30.days, CatalogSyncer.send(:history_lookback)
  end

  test "history_lookback honors SYNC_HISTORY_DAYS" do
    EnvStore.set("SYNC_HISTORY_DAYS", "3650")
    assert_equal 3650.days, CatalogSyncer.send(:history_lookback)
  end

  test "paginate_orders walks all pages" do
    page1 = { "orders" => { "nodes" => [{ "id" => "a" }, { "id" => "b" }],
                            "pageInfo" => { "hasNextPage" => true, "endCursor" => "c1" } } }
    page2 = { "orders" => { "nodes" => [{ "id" => "c" }],
                            "pageInfo" => { "hasNextPage" => false, "endCursor" => "c2" } } }

    ShopifyClient.stubs(:graphql)
                 .returns(page1)
                 .then.returns(page2)

    result = CatalogSyncer.send(:paginate_orders, "2026-01-01")

    assert_equal %w[a b c], result["nodes"].map { |n| n["id"] }
    refute result["pageInfo"]["hasNextPage"]
  end

  test "paginate_products walks all pages instead of truncating at 250" do
    page1 = { "products" => { "nodes" => [{ "id" => "p1" }, { "id" => "p2" }],
                              "pageInfo" => { "hasNextPage" => true, "endCursor" => "c1" } } }
    page2 = { "products" => { "nodes" => [{ "id" => "p3" }],
                              "pageInfo" => { "hasNextPage" => false, "endCursor" => "c2" } } }

    ShopifyClient.stubs(:graphql)
                 .returns(page1)
                 .then.returns(page2)

    result = CatalogSyncer.send(:paginate_products)

    assert_equal %w[p1 p2 p3], result.map { |n| n["id"] }
  end

  test "sync_variant! mirrors one level per Shopify location" do
    home = Location.create!(source: "shopify", externalId: "gid://shopify/Location/1", name: "Online")
    rig = Location.create!(source: "shopify", externalId: "gid://shopify/Location/2", name: "Market Rig")
    ShopifyProduct.create!(id: "gid://shopify/Product/1", title: "Tea")
    AlertGenerator.stubs(:sync_variant!).returns(nil)

    variant = {
      "id" => "gid://shopify/ProductVariant/9",
      "title" => "Tea / 50g",
      "sku" => "TEA-50",
      "price" => "12.00",
      "inventoryQuantity" => 7,
      "inventoryItem" => {
        "id" => "gid://shopify/InventoryItem/9",
        "tracked" => true,
        "inventoryLevels" => {
          "nodes" => [
            { "location" => { "id" => "gid://shopify/Location/1" },
              "quantities" => [{ "name" => "available", "quantity" => 5 }] },
            { "location" => { "id" => "gid://shopify/Location/2" },
              "quantities" => [{ "name" => "available", "quantity" => 2 }] },
          ],
        },
      },
    }

    CatalogSyncer.send(:sync_variant!, "gid://shopify/Product/1", variant,
      { "gid://shopify/Location/1" => home, "gid://shopify/Location/2" => rig }, home)

    levels = InventoryLevel.where(source: "shopify", shopifyVariantId: variant["id"])
    assert_equal 2, levels.count
    assert_equal 5, levels.find_by(locationId: home.id).quantity
    assert_equal 2, levels.find_by(locationId: rig.id).quantity
    # Rows are keyed by the Location record id so level.location resolves.
    assert_equal home.id, levels.find_by(locationId: home.id).location&.id
  end

  test "sync_variant! falls back to the primary row when no levels are returned" do
    primary = Location.create!(source: "shopify", externalId: "gid://shopify/Location/1", name: "Online")
    ShopifyProduct.create!(id: "gid://shopify/Product/1", title: "Poster")
    AlertGenerator.stubs(:sync_variant!).returns(nil)

    variant = {
      "id" => "gid://shopify/ProductVariant/10",
      "title" => "Poster",
      "sku" => nil,
      "inventoryQuantity" => 3,
      "inventoryItem" => { "id" => "gid://shopify/InventoryItem/10", "tracked" => false },
    }

    CatalogSyncer.send(:sync_variant!, "gid://shopify/Product/1", variant, {}, primary)

    levels = InventoryLevel.where(source: "shopify", shopifyVariantId: variant["id"])
    assert_equal 1, levels.count
    assert_equal 3, levels.find_by(locationId: primary.id).quantity
  end

  test "prune_stale_shopify_levels! removes rows for vanished locations and guards an empty map" do
    known = Location.create!(source: "shopify", externalId: "gid://shopify/Location/1", name: "Online")
    variant = ShopifyVariant.create!(productId: "p-x", title: "X", sku: "X-1")
    InventoryLevel.create!(source: "shopify", locationId: known.id, shopifyVariantId: variant.id, quantity: 1)
    stale = InventoryLevel.create!(source: "shopify", locationId: "c-gone-location", shopifyVariantId: variant.id, quantity: 4)

    assert_equal 1, CatalogSyncer.send(:prune_stale_shopify_levels!)
    assert_not InventoryLevel.exists?(stale.id)
    assert InventoryLevel.where(source: "shopify", locationId: known.id).exists?

    # Transient API failure left us with zero known locations — never bulk-delete.
    Location.by_source("shopify").delete_all
    InventoryLevel.create!(source: "shopify", locationId: "c-another", shopifyVariantId: variant.id, quantity: 2)
    assert_equal 0, CatalogSyncer.send(:prune_stale_shopify_levels!)
  end

  test "assign_shopify_primary! flags the first active location and honors SHOPIFY_LOCATION_ID" do
    a = Location.create!(source: "shopify", externalId: "gid://shopify/Location/1", name: "Online")
    b = Location.create!(source: "shopify", externalId: "gid://shopify/Location/2", name: "Rig")

    nodes = [
      { "id" => "gid://shopify/Location/1", "isActive" => true },
      { "id" => "gid://shopify/Location/2", "isActive" => true },
    ]
    CatalogSyncer.send(:assign_shopify_primary!, nodes)
    assert_predicate a.reload, :primary_location?
    refute b.reload.primary_location?
    assert_equal a.id, Location.shopify_primary.id

    # An explicit pin moves the flag; the old flag is cleared.
    EnvStore.set("SHOPIFY_LOCATION_ID", "gid://shopify/Location/2")
    CatalogSyncer.send(:assign_shopify_primary!, nodes)
    assert_equal b.id, Location.shopify_primary.id
    refute a.reload.primary_location?
  ensure
    Setting.where(key: "SHOPIFY_LOCATION_ID").delete_all
    EnvStore.instance_variable_set(:@cache, {}) if EnvStore.instance_variable_defined?(:@cache)
  end
end
