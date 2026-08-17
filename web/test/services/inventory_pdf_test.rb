# frozen_string_literal: true

require "test_helper"

class InventoryPdfServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @product = ShopifyProduct.create!(id: "pdf-p1", title: "CBD Tincture")
    120.times do |i|
      ShopifyVariant.create!(
        title: "Variant #{i}",
        sku: "PDF-#{i}",
        productId: @product.id,
        price: 10.0 + i,
        inventoryQuantity: i + 1,
      )
    end
    SyncRun.create!(
      mode: "scheduled",
      status: "success",
      source: "all",
      startedAt: 1.hour.ago,
      finishedAt: 55.minutes.ago,
    )
  end

  teardown do
    Current.tenant = nil
  end

  test "renders a valid PDF that covers every variant across multiple pages" do
    pdf = InventoryPdf.new
    assert_equal 120, pdf.rows.length, "export covers the whole catalog, not the 40-row page preview"

    doc = pdf.document
    # 120 rows at a compact 7pt grid cannot fit on one LETTER page, so the
    # export spills onto later pages to prove genuine full-catalog coverage.
    assert_operator doc.page_count, :>=, 2, "120 rows should overflow onto a second page"

    bytes = InventoryPdf.build
    assert bytes.start_with?("%PDF-1"), "output looks like a PDF"
  end

  test "includes units sold in the last 7 days per SKU" do
    loc = Location.create!(source: "square", externalId: "loc-sold", name: "Main shop")
    order = Core::Order.new(
      source: "square",
      source_order_id: "sq-sold-1",
      channel: "pos",
      gross_cents: 3000,
      tax_cents: 0,
      occurred_at: 2.days.ago,
      location_id: loc.externalId,
    )
    order.mark_paid!
    order.save!
    order.order_lines.create!(tenant_id: @tenant.id, sku: "PDF-1", name: "Variant 1", quantity: 3, line_cents: 3000)

    # A refunded order's sales must NOT count.
    refunded = Core::Order.new(
      source: "square",
      source_order_id: "sq-refund-1",
      channel: "pos",
      gross_cents: 5000,
      tax_cents: 0,
      occurred_at: 1.day.ago,
      location_id: loc.externalId,
    )
    refunded.mark_paid!
    refunded.save!
    refunded.order_lines.create!(tenant_id: @tenant.id, sku: "PDF-1", name: "Variant 1", quantity: 2, line_cents: 5000)
    refunded.refund!

    row = InventoryPdf.new.rows.find { |r| r.sku == "PDF-1" }
    assert_equal 3, row.sold_7d
  end

  test "zero-stock-on-both rows are sorted to the bottom" do
    ShopifyVariant.create!(
      title: "Zero Stock Item",
      sku: "PDF-ZERO",
      productId: @product.id,
      price: 5.0,
      inventoryQuantity: 0,
    )
    sq = SquareItem.create!(id: "sq-zero", name: "Zero Stock")
    sv = SquareVariation.create!(id: "sq-var-zero", itemId: "sq-zero", name: "Zero Stock", sku: "PDF-ZERO")
    variant = ShopifyVariant.find_by(sku: "PDF-ZERO")
    SkuLink.create!(sku: "PDF-ZERO", shopifyVariantId: variant.id, squareVariationId: sv.id)
    loc = Location.create!(source: "square", externalId: "loc-zero", name: "Main shop")
    InventoryLevel.create!(source: "square", locationId: loc.externalId, squareVariationId: sv.id, quantity: 0)
    InventoryLevel.create!(source: "shopify", locationId: "shop-loc", shopifyVariantId: variant.id, quantity: 0)

    rows = InventoryPdf.new.rows
    assert_equal "PDF-ZERO", rows.last.sku, "zero-stock-on-both items land at the bottom"
    assert rows.first(rows.length - 1).none? { |r| r.sku == "PDF-ZERO" }, "stocked items all sort above the zero-stock block"
  end

  test "sales week groups by day, newest first, with per-day transactions" do
    loc = Location.create!(source: "square", externalId: "loc-sw", name: "Main shop")
    3.times do |i|
      order = Core::Order.new(
        source: "square",
        source_order_id: "sq-sw-#{i}",
        channel: "pos",
        gross_cents: 1000 * (i + 1),
        tax_cents: 0,
        occurred_at: i.days.ago,
        location_id: loc.externalId,
      )
      order.mark_paid!
      order.save!
      order.order_lines.create!(tenant_id: @tenant.id, sku: "PDF-1", name: "Variant 1", quantity: i + 1, line_cents: 1000 * (i + 1))
    end

    week = InventoryPdf.new.send(:sales_week_data)
    assert_equal 3, week.length
    assert_operator week[0][0], :>, week[1][0], "days are newest first"
    assert_equal 1, week[0][1].sum { |o| o.order_lines.sum(:quantity) }, "today's unit total"
  end

  test "shared SKUs flag the sold count as covering multiple variants and transactions show the product name" do
    # A second variant carrying the same SKU as PDF-1.
    ShopifyVariant.create!(title: "Variant 1 (dup)", sku: "PDF-1", productId: @product.id, price: 9.0, inventoryQuantity: 1)

    order = Core::Order.new(
      source: "shopify",
      source_order_id: "sh-shared-1",
      channel: "online",
      gross_cents: 2000,
      tax_cents: 0,
      occurred_at: 1.day.ago,
    )
    order.mark_paid!
    order.save!
    order.order_lines.create!(tenant_id: @tenant.id, sku: "PDF-1", name: "CBD Tincture - 1000mg", quantity: 2, line_cents: 2000)

    pdf = InventoryPdf.new
    shared_rows = pdf.rows.select { |r| r.sku == "PDF-1" }
    assert_equal 2, shared_rows.length, "both variants share the SKU"
    shared_rows.each do |row|
      assert row.sold_shared, "shared SKU should be flagged"
      assert_equal 2, row.sold_7d, "SKU-level sold total is shown on every variant carrying it"
      assert_equal "2†", pdf.send(:sold_cell, row), "sold cell marks the shared-SKU total"
    end
    assert_includes pdf.send(:item_summary, order), "CBD Tincture - 1000mg (PDF-1)"
  end

  test "cross-product duplicate SKUs are flagged for rose highlighting" do
    other = ShopifyProduct.create!(id: "pdf-p2", title: "Other Tincture")
    ShopifyVariant.create!(title: "Dup", sku: "PDF-1", productId: other.id, price: 8.0, inventoryQuantity: 2)

    rows = InventoryPdf.new.rows.select { |r| r.sku == "PDF-1" }
    assert_equal 2, rows.length
    assert rows.all?(&:shared_product_sku), "every variant carrying a cross-product SKU is flagged"
  end
end