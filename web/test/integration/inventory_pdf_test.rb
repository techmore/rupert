# frozen_string_literal: true

require "test_helper"

class InventoryPdfTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    post login_path, params: { email: "admin@example.com", password: "password" }

    ShopifyProduct.create!(id: "p1", title: "CBD", totalInventory: 3)
    @shopify_variant = ShopifyVariant.create!(
      title: "Oil",
      sku: "OIL-1",
      productId: "p1",
      price: 25.0,
      inventoryQuantity: 3,
    )

    @loc = Location.create!(source: "square", externalId: "loc1", name: "Main Shop")
    SquareItem.create!(id: "sqitem1", name: "CBD")
    @square_variation = SquareVariation.create!(itemId: "sqitem1", name: "Oil", sku: "OIL-1")

    SkuLink.create!(
      sku: "OIL-1",
      shopifyVariantId: @shopify_variant.id,
      squareVariationId: @square_variation.id,
    )
    InventoryLevel.create!(
      source: "square",
      locationId: @loc.externalId,
      squareVariationId: @square_variation.id,
      quantity: 5,
    )
    InventoryLevel.create!(
      source: "shopify",
      locationId: "shop-loc",
      shopifyVariantId: @shopify_variant.id,
      quantity: 3,
    )
    SyncRun.create!(
      mode: "scheduled",
      status: "success",
      source: "all",
      startedAt: 30.minutes.ago,
      finishedAt: 28.minutes.ago,
    )
  end

  teardown do
    Current.tenant = nil
  end

  test "downloads a PDF snapshot of the current inventory" do
    get pdf_inventory_index_path

    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_includes response.headers["Content-Disposition"], "attachment"
    assert_includes response.headers["Content-Disposition"], "inventory-"
    assert response.body.start_with?("%PDF")
  end

  test "inventory page shows the download link" do
    get inventory_index_path
    assert_response :success
    assert_select "a[href=?]", pdf_inventory_index_path
  end
end