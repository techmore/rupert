# frozen_string_literal: true

require "test_helper"

class RestockAdvisorTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant_id = Current.tenant_id

    @product = ShopifyProduct.create!(id: "gid://shopify/Product/1", title: "Tea", status: "ACTIVE")
    @variant = ShopifyVariant.create!(productId: @product.id, title: "Tea / 50g", sku: "TEA-50",
      inventoryQuantity: 5, tracked: true)
    @online = Location.create!(source: "shopify", externalId: "loc-1", name: "Online")
    InventoryLevel.create!(source: "shopify", locationId: @online.id, shopifyVariantId: @variant.id,
      quantity: 5, available: 5)

    @item = SquareItem.create!(id: "si1", name: "Tea Item")
    @variation = SquareVariation.create!(id: "sv1", itemId: @item.id, sku: "TEA-50", name: "Tea 50g")
    @home = Location.create!(source: "square", externalId: "sq-1", name: "Home shop")
    @rig = Location.create!(source: "square", externalId: "sq-2", name: "Rig")
    InventoryLevel.create!(source: "square", locationId: @home.id, squareVariationId: @variation.id, quantity: 3, available: 3)
    InventoryLevel.create!(source: "square", locationId: @rig.id, squareVariationId: @variation.id, quantity: 4, available: 4)

    # 30 units sold over the trailing window => 1/day pace.
    add_sales!("TEA-50", 30, 20.days.ago)
    # 6 more inside the 14-day window.
    add_sales!("TEA-50", 6, 7.days.ago)

    @alert = StockAlert.create!(sku: "TEA-50", quantity: 5, threshold: 8, status: "open",
      shopifyVariantId: @variant.id)
    @quiet_variant = ShopifyVariant.create!(productId: @product.id, title: "Incense Stick", sku: "QUIET-1",
      inventoryQuantity: 2, tracked: true)
    @quiet = StockAlert.create!(sku: "QUIET-1", quantity: 2, threshold: 5, status: "open",
      shopifyVariantId: @quiet_variant.id)
  end

  teardown { Current.tenant = nil }

  def add_sales!(sku, qty, occurred_at)
    order = Core::Order.new(
      source: "square", source_order_id: "o-#{sku}-#{occurred_at.to_i}",
      channel: "pos", occurred_at: occurred_at, gross_cents: 0,
    )
    order.mark_paid! # status is AASM-managed; no direct assignment
    Core::OrderLine.create!(order_id: order.id, sku: sku.upcase, name: "Tea", quantity: qty, unit_cents: 0, line_cents: 0)
  end

  test "computes per-location stock, velocity, cover, and a ~30-day suggestion" do
    rows = RestockAdvisor.for_alerts([@alert])
    row = rows[@alert.id]

    assert_equal 5, row.shop_qty
    assert_equal 7, row.pos_qty            # 3 home + 4 rig
    assert_equal 6, row.sold_14
    assert_equal 36, row.sold_30           # 30 + 6
    # on hand 12 at 36/30 = 1.2/day -> 10 days of cover
    assert_in_delta 10.0, row.days_of_cover, 0.1
    # (1.2 * 30).ceil = 36 -> reorder 24 to cover ~30 days
    assert_equal 24, row.suggested_qty
  end

  test "skus with no recent sales get no suggestion instead of a fake number" do
    rows = RestockAdvisor.for_alerts([@alert, @quiet])

    assert_nil rows[@quiet.id].days_of_cover
    assert_nil rows[@quiet.id].suggested_qty
    assert_equal 0, rows[@quiet.id].sold_30
  end

  test "suggestion never goes negative when stock already covers the window" do
    InventoryLevel.find_by(source: "shopify", locationId: @online.id, shopifyVariantId: @variant.id)
      &.update!(quantity: 500, available: 500)

    rows = RestockAdvisor.for_alerts([@alert])
    assert_equal 0, rows[@alert.id].suggested_qty
  end
end
