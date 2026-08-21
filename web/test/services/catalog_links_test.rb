# frozen_string_literal: true

require "test_helper"

class CatalogLinksTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @product = ShopifyProduct.create!(id: "gid://shopify/Product/1", title: "Tea", status: "ACTIVE")
  end

  teardown { Current.tenant = nil }

  def square_variation!(sku:)
    item = SquareItem.create!(id: "si-#{sku}", name: "Tea Item", tenant_id: Current.tenant_id)
    SquareVariation.create!(id: "sv-#{sku}", itemId: item.id, sku: sku, name: "Tea 50g", tenant_id: Current.tenant_id)
  end

  def link_variant!(sku:, variation:)
    variant = ShopifyVariant.create!(productId: @product.id, title: "Tea / 50g", sku: sku, inventoryQuantity: 3)
    SkuLink.create!(sku: sku, shopifyVariantId: variant.id, squareVariationId: variation&.id)
    variant
  end

  test "rows classify matched and mismatched links, mismatches first" do
    good = square_variation!(sku: "TEA-50")
    bad = square_variation!(sku: "WRONG-9")

    link_variant!(sku: "TEA-50", variation: good)
    link_variant!(sku: "TEA-100", variation: bad)

    rows = CatalogLinks.rows
    assert_equal 2, rows.length
    assert_equal %w[mismatched matched], rows.map(&:status)
    mismatch = rows.first
    assert_equal "TEA-100", mismatch.sku
    assert_equal "WRONG-9", mismatch.square_sku
  end

  test "summary counts linked, matched, mismatched, and one-sided items" do
    good = square_variation!(sku: "TEA-50")
    link_variant!(sku: "TEA-50", variation: good)
    link_variant!(sku: "SOLO-1", variation: nil)          # Shopify-only (no link)
    square_variation!(sku: "SQ-ONLY-1")                    # Square-only (unlinked)

    summary = CatalogLinks.summary

    assert_equal 1, summary[:linked]
    assert_equal 1, summary[:matched]
    assert_equal 0, summary[:mismatched]
    assert_operator summary[:shopify_only], :>=, 1
    assert_operator summary[:square_only], :>=, 1
  end

  test "mismatched count drives the dashboard attention item" do
    bad = square_variation!(sku: "WRONG-9")
    link_variant!(sku: "TEA-100", variation: bad)

    presenter = DashboardPresenter.new
    assert_equal 1, presenter.sku_mismatches
  end
end
