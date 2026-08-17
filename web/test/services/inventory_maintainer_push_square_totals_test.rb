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
end
