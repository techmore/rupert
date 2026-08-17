# frozen_string_literal: true

require "test_helper"

class InventoryPdfServiceTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
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
    # 120 rows at ~8pt cannot fit on one LETTER page, so the export spills onto
    # later pages to prove genuine full-catalog coverage.
    assert_operator doc.page_count, :>=, 2, "120 rows should overflow onto a second page"

    bytes = InventoryPdf.build
    assert bytes.start_with?("%PDF-1"), "output looks like a PDF"
  end
end