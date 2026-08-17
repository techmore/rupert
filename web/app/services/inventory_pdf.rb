# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Built-in AFM fonts cover WinAnsi (the em dash / middle dot / accented Latin
# glyphs this report uses), so the per-document M17N warning is noise here.
Prawn::Fonts::AFM.hide_m17n_warning = true

# Builds the printable "Current Inventory Snapshot" for the Inventory page's
# Download PDF button. Data comes from the sync mirrors (refreshed every
# 15 minutes), so the PDF carries four timestamps: when the file was
# generated, the last successful overall sync, and the latest Shopify and
# Square mirror writes. Below the timestamps it shows summary totals, then a
# full per-variant table with Shopify qty, Square qty, drift, and units sold
# in the last 7 days.
#
# Layout choices:
#   - "… difference" rows (non-zero drift) are tinted and the drift value is
#     colored and bold
#   - items with zero stock on BOTH platforms are sorted to the bottom
#   - a compact 7pt row grid fits far more content per page
#
# Performance note: the catalog table is drawn with Prawn's low-level
# draw_text (no prawn-table Cell objects). Prawing 1900+ Cell objects to
# render a few hundred variant rows costs ~3s of pure Ruby; low-level text
# placement renders the same table in well under 200ms.
class InventoryPdf
  # Tailwind-ish neutrals that survive Prawn's base Helvetica palette.
  INK = "1C1917"
  MOCHA = "6B7280"
  TAUPE = "A8A29E"
  FOG = "D6D3D1"
  HAZE = "EDEFF0"
  CREAM = "FAFAF9"
  CLAY = "B45309"
  OLIVE = "5B7C41"
  DRIFT_TINT = "FFF4E0"  # pale amber — non-zero drift rows
  ZERO_TINT = "F5F0EC"   # pale stone — zero-stock-on-both rows

  Row = Struct.new(
    :product, :variant, :sku, :price, :shopify_qty, :square_qty, :drift,
    :sold_7d,
    keyword_init: true
  )

  # "—" for an unlinked variant's Square count, so the column reads like the
  # Inventory page table instead of showing a misleading zero.
  UNLINKED = "—"

  # Letter width 612 - 2×40 margin = 532pt of usable width.
  HEADERS = ["Product", "Variant", "SKU", "Price", "Shopify", "Square", "Drift", "7d sold"].freeze
  COL_WIDTHS = [128, 104, 56, 46, 42, 42, 44, 70].freeze
  LEFT_X = [40, 168, 272, 328, 374, 416, 458, 502].freeze
  RIGHT_ALIGNED = [3, 4, 5, 6, 7].freeze
  TABLE_WIDTH = 532
  ROW_HEIGHT = 12
  HEADER_HEIGHT = 14
  FONT_SIZE = 7
  FOOTER_TOP = 52
  SALES_DAYS = 7

  def self.build
    new.build
  end

  def build
    document.render
  end

  # The full per-variant snapshot the PDF renders (exposed for tests).
  def rows
    @rows ||= load_rows
  end

  # The Prawn document itself, exposed so tests can check page_count etc.
  def document
    @document ||= build_document
  end

  private

  def build_document
    summary = summarize(rows)
    timestamps = snapshot_timestamps

    Prawn::Document.new(page_size: "LETTER", margin: 40) do |pdf|
      write_header(pdf, timestamps)
      write_summary(pdf, summary)
      write_table(pdf, rows)
      write_footer(pdf)
    end
  end

  def snapshot_timestamps
    {
      generated: Time.current,
      overall: last_successful_sync_time,
      shopify: ShopifyVariant.maximum(:syncedAt),
      square: SquareVariation.maximum(:syncedAt)
    }
  end

  def last_successful_sync_time
    run = SyncRun.where(status: "success").order(finishedAt: :desc).first
    return nil unless run

    run.finishedAt || run.startedAt
  end

  # Units sold per SKU over the configured window, from the canonical sales
  # store (paid/fulfilled orders only).
  def sales_since(days)
    Core::OrderLine.joins(:order)
      .where(orders: { status: ["paid", "fulfilled"], occurred_at: days.days.ago.beginning_of_day..Time.current })
      .group(:sku).sum(:quantity)
  end

  # Mirrors the Inventory page's row shape (product-first ordering) but covers
  # the whole catalog rather than the page's 40-row preview. Zero-stock-on-both
  # rows are moved to the bottom so buyers see sellable stock first.
  def load_rows
    shopify_map = InventoryLevel.where(source: "shopify").group(:shopifyVariantId).sum(:quantity)
    square_map = InventoryLevel.where(source: "square").group(:squareVariationId).sum(:quantity)
    link_map = SkuLink.linked.index_by(&:shopifyVariantId)
    sold = sales_since(SALES_DAYS)

    rows = ShopifyProduct.order(:title).includes(:variants).flat_map do |product|
      product.variants.sort_by(&:title).map do |variant|
        link = link_map[variant.id]
        square_qty = link ? square_map.fetch(link.squareVariationId, 0) : nil
        shopify_qty = shopify_map.fetch(variant.id, 0)
        Row.new(
          product: product.title,
          variant: variant.title,
          sku: variant.sku.presence || "—",
          price: variant.price,
          shopify_qty: shopify_qty,
          square_qty: square_qty,
          drift: square_qty ? square_qty - shopify_qty : nil,
          sold_7d: variant.sku.present? ? sold.fetch(variant.sku, 0) : nil
        )
      end
    end
    zeroed, stocked = rows.partition { |row| zero_on_both?(row) }
    stocked + zeroed
  end

  def zero_on_both?(row)
    row.shopify_qty.to_i <= 0 && row.square_qty.present? && row.square_qty <= 0
  end

  def summarize(rows)
    {
      products: rows.map(&:product).uniq.size,
      variants: rows.length,
      shopify_units: rows.sum { |row| row.shopify_qty.to_i },
      square_units: rows.sum { |row| row.square_qty.to_i },
      sold_7d: rows.sum { |row| row.sold_7d.to_i },
      valuation: rows.sum { |row| (row.price || 0).to_f * row.shopify_qty.to_i }
    }
  end

  def write_header(pdf, timestamps)
    pdf.text "Current Inventory Snapshot", size: 19, style: :bold, color: INK
    pdf.move_down 2
    pdf.text tenant_line, size: 10, color: MOCHA
    pdf.move_down 12

    pdf.text "Timestamps", size: 11, style: :bold, color: INK
    pdf.move_down 4
    stamp_rows = [
      ["Generated at", fmt(timestamps[:generated])],
      ["Overall last sync", fmt(timestamps[:overall])],
      ["Shopify last sync", fmt(timestamps[:shopify])],
      ["Square last sync", fmt(timestamps[:square])],
    ]
    pdf.table(stamp_rows, width: 340, column_widths: [150, 190]) do |table|
      table.cells.padding = [2.5, 6]
      table.cells.borders = [:bottom]
      table.cells.border_color = FOG
      table.cells.font_size = 8.5
      table.cells.text_color = MOCHA
      table.column(0).font_style = :bold
      table.column(0).text_color = INK
    end
    pdf.move_down 14

    pdf.text "Summary", size: 11, style: :bold, color: INK
    pdf.move_down 4
  end

  def write_summary(pdf, summary)
    labels = ["Products", "Variants", "Shopify units", "Square units", "Sold 7d", "Retail value"]
    values = [
      summary[:products].to_s,
      summary[:variants].to_s,
      summary[:shopify_units].to_s,
      summary[:square_units].to_s,
      summary[:sold_7d].to_s,
      format_currency(summary[:valuation]),
    ]
    pdf.table([labels, values], width: TABLE_WIDTH, column_widths: [TABLE_WIDTH / 6.0] * 6) do |table|
      table.cells.padding = [5, 6]
      table.cells.borders = [:bottom]
      table.cells.border_color = FOG
      table.cells.font_size = 8.5
      table.row(0).font_style = :bold
      table.row(0).background_color = HAZE
      table.row(0).text_color = MOCHA
      table.row(1).text_color = INK
    end
    pdf.move_down 14
  end

  # --- Catalog table ---------------------------------------------------------
  #
  # Hand-rolled rows with draw_text (no prawn-table cells): ~16x faster than
  # prawn-table for catalogs of a few hundred rows.

  def write_table(pdf, rows)
    if rows.empty?
      pdf.text "No inventory mirrored yet — run a sync from the Sync page.", size: 10, color: TAUPE
      return
    end

    pdf.font "Helvetica", size: FONT_SIZE
    y = pdf.cursor
    draw_table_header(pdf, y)
    y -= HEADER_HEIGHT + 3

    rows.each_with_index do |row, index|
      if y - ROW_HEIGHT < FOOTER_TOP
        pdf.start_new_page
        y = pdf.cursor
        draw_table_header(pdf, y)
        y -= HEADER_HEIGHT + 3
      end

      draw_row_background(pdf, row, y, index)
      draw_row(pdf, row, y)
      pdf.stroke_color FOG
      pdf.stroke_horizontal_line 40, 40 + TABLE_WIDTH, at: y - 2
      y -= ROW_HEIGHT
    end
  end

  def draw_table_header(pdf, y)
    pdf.fill_color HAZE
    pdf.fill_rectangle [40, y], TABLE_WIDTH, HEADER_HEIGHT
    pdf.fill_color MOCHA
    pdf.font "Helvetica", style: :bold
    HEADERS.each_with_index do |header, i|
      pdf.draw_text header, at: [LEFT_X[i] + 4, y - HEADER_HEIGHT / 2 + 1], size: FONT_SIZE
    end
    pdf.font "Helvetica", style: :normal
    pdf.fill_color INK
  end

  # Highlights differences: drift rows get an amber tint, zero-stock rows a
  # stone tint, and the rest keep the subtle cream zebra stripe.
  def draw_row_background(pdf, row, y, index)
    if !row.drift.nil? && !row.drift.zero?
      pdf.fill_color DRIFT_TINT
    elsif zero_on_both?(row)
      pdf.fill_color ZERO_TINT
    elsif index.even?
      pdf.fill_color CREAM
    else
      return
    end
    pdf.fill_rectangle [40, y], TABLE_WIDTH, ROW_HEIGHT
    pdf.fill_color INK
  end

  def draw_row(pdf, row, y)
    cells = [
      row.product,
      row.variant,
      row.sku,
      row.price.nil? ? "—" : format_currency(row.price),
      row.shopify_qty.to_s,
      row.square_qty.nil? ? UNLINKED : row.square_qty.to_s,
      row.drift.nil? ? "—" : (row.drift.zero? ? "—" : format("%+d", row.drift)),
      row.sold_7d.nil? ? "—" : row.sold_7d.to_s,
    ]
    baseline = y - ROW_HEIGHT / 2 + 1
    cells.each_with_index do |cell, i|
      pdf.fill_color cell_color(i, row)
      bold = bold_cell?(i, row)
      pdf.font("Helvetica", style: :bold) if bold
      if RIGHT_ALIGNED.include?(i)
        x = LEFT_X[i] + COL_WIDTHS[i] - 3 - pdf.width_of(cell)
      else
        x = LEFT_X[i] + 4
      end
      pdf.draw_text fit_text(pdf, cell, COL_WIDTHS[i] - 7), at: [x, baseline], size: FONT_SIZE
      pdf.font("Helvetica", style: :normal) if bold
    end
    pdf.fill_color INK
  end

  def cell_color(index, row)
    if index == 6 && !row.drift.nil? && !row.drift.zero?
      CLAY
    elsif index == 7 && !row.sold_7d.nil? && row.sold_7d.positive?
      OLIVE
    elsif index.zero?
      INK
    else
      MOCHA
    end
  end

  def bold_cell?(index, row)
    (index == 6 && !row.drift.nil? && !row.drift.zero?) ||
      (index == 7 && !row.sold_7d.nil? && row.sold_7d.positive?)
  end

  # Truncate to the column width with an ellipsis so long product/variant names
  # never spill into the next column.
  def fit_text(pdf, text, max_width)
    text = text.to_s
    return text if pdf.width_of(text) <= max_width

    ellipsis = "…"
    clipped = text.dup
    clipped = clipped[0...-1] while clipped.length > 1 && pdf.width_of(clipped + ellipsis) > max_width
    clipped + ellipsis
  end

  def write_footer(pdf)
    pdf.move_down 10
    pdf.text(
      "Generated by Rupert. Quantities are mirrored from Shopify and Square and refresh every 15 minutes; " \
      "tinted rows show a Shopify vs Square difference; zero-stock rows sit at the bottom; " \
      "7d sold counts paid/fulfilled orders from the last #{SALES_DAYS} days; " \
      "unlinked variants show #{UNLINKED} for Square.",
      size: 6.5, color: TAUPE,
    )
    pdf.number_pages(
      "Page <page> of <total>",
      at: [pdf.bounds.left, 16],
      width: pdf.bounds.width,
      align: :right,
      size: 6.5,
      color: TAUPE,
    )
  end

  def tenant_line
    name = Current.respond_to?(:tenant) && Current.tenant
    base = "Rupert · Shopify + Square inventory mirror"
    name ? "#{base} — #{name.name}" : base
  end

  def format_currency(amount)
    format("$%.2f", amount.to_f)
  end

  # Localized * app timezone, e.g. "August 17, 2026 · 2:05 PM UTC".
  def fmt(time)
    return "—" if time.nil?

    time.in_time_zone.strftime("%B %-e, %Y · %-l:%M %p %Z")
  end
end