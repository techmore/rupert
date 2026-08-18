# frozen_string_literal: true

require "test_helper"

class InventoryMaintainerPushSquareTotalsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    PlatformPushGuard.unfreeze!("shopify", actor: "test")
    @loc = Location.create!(source: "shopify", externalId: "shop-loc", name: "Online", syncedAt: Time.current)
    Location.create!(source: "square", externalId: "sq-loc", name: "Store", syncedAt: Time.current)
    @variant = ShopifyVariant.create!(sku: "TOT-1", title: "Item", tracked: true,
      inventoryItemId: "ii1", inventoryQuantity: 2, productId: "p1")
    @sq_variation = SquareVariation.create!(id: "sqtot1", itemId: "i1", sku: "TOT-1", name: "Item")
    @link = SkuLink.create!(sku: "TOT-1", shopifyVariantId: @variant.id, squareVariationId: @sq_variation.id)
    InventoryLevel.create!(source: "square", locationId: "sq-loc", squareVariationId: @sq_variation.id, quantity: 5)
  end

  teardown do
    Current.tenant = nil
  end

  test "skips when Shopify already matches Square" do
    InventoryLevel.create!(source: "shopify", locationId: @loc.externalId, shopifyVariantId: @variant.id, quantity: 5)
    @variant.update!(inventoryQuantity: 5)
    ShopifyClient.expects(:graphql).never

    result = InventoryMaintainer.push_square_totals!(actor: "test")

    assert_equal 1, result[:linked]
    assert_equal 0, result[:pushed]
    assert_equal 1, result[:skipped]
  end

  test "pushes the Square total and journals a reconcile movement when they differ" do
    @variant.update!(inventoryQuantity: 2)
    ShopifyClient.stubs(:graphql).returns({ "inventoryAdjustQuantities" => { "userErrors" => [] } })
    InventoryMaintainer.stubs(:shopify_level).returns(2) # live Shopify available

    result = InventoryMaintainer.push_square_totals!(actor: "test")

    assert_equal 1, result[:pushed]
    movement = InventoryMovement.last
    assert_equal "reconcile", movement.source
    assert_equal 2, movement.quantityBefore
    assert_equal 5, movement.quantityAfter
    assert_equal 3, movement.delta
    assert_equal "Square-as-truth push", movement.reason
  end

  test "the AdjustInventory idempotency key is unique per adjustment" do
    # Regression: the writer previously keyed on SKU+delta only (as part of
    # InventoryMaintainer#push_shopify!). Shopify keeps keys for a long time, so
    # a recurring (variant, delta, starting qty) on the 15-min cycle was
    # re-submitted and rejected as "different parameters", failing the reconcile
    # push every cycle. The key must carry a per-run token AND the starting
    # quantity.
    captured = {}
    ShopifyClient.stubs(:graphql).with do |_q, variables|
      captured[:changeFromQuantity] = variables.dig(:input, :changes, 0, :changeFromQuantity)
      captured[:key] = variables[:idempotencyKey]
      true
    end.returns({ "inventoryAdjustQuantities" => { "userErrors" => [] } })

    InventoryWriter.adjust_shopify!(
      inventory_item_id: @variant.inventoryItemId,
      delta: -5,
      location: @loc,
      reference: "pool-sync",
      change_from: 10,
      idempotency_key: InventoryWriter.per_run_key("hh-pool", @variant.sku, @variant.id, 10, -5),
    )

    assert_equal 10, captured[:changeFromQuantity]
    assert_includes captured[:key], "10->-5", "key must carry the starting quantity and delta"
    assert_match(/hh-pool-.*-\d+-\d+->-5\z/, captured[:key], "key must carry a per-run token")
  end

  test "skips a linked SKU whose Square stock spans multiple locations (no half-push)" do
    # Regression: a Square variation with concurrent stock in >1 location can't be
    # represented by a single home PHYSICAL_COUNT (or a single Shopify target).
    # It must be skipped from the Square-as-truth push, not half-applied.
    second_loc = Location.create!(source: "square", externalId: "sq-loc-2", name: "Vendor Rig", syncedAt: Time.current)
    InventoryLevel.create!(source: "square", locationId: second_loc.id, squareVariationId: @sq_variation.id, quantity: 7)
    # home 5 + rig 7 = 12 across two locations
    @variant.update!(inventoryQuantity: 2)
    ShopifyClient.stubs(:graphql).never

    result = InventoryMaintainer.push_square_totals!(actor: "test")

    assert_equal 1, result[:linked]
    assert_equal 0, result[:pushed]
    assert_equal 1, result[:skipped], "multi-location SKU must be skipped, not pushed"
    assert_includes result[:per_sku].first[:actions].join, "multiple locations"
    assert_nil result[:per_sku].first[:target]
  end
end
