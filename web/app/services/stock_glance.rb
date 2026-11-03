# frozen_string_literal: true

# "Is it in stock?" for a search: each matching item once, with what can be sold
# at every location, what C-Trax counted at each store and Rupert's own number
# per site. Each figure keeps its own source and read time; nothing is added up
# across sources.
class StockGlance
  LIMIT = 8
  Figure = Struct.new(:place, :quantity, :fresh, :row, keyword_init: true)
  # row: the first InventoryWorkspace row, for StockHelper#stock_item_name and #stock_item_sku.
  Item = Struct.new(:row, :native_id, :source, :pools, :ctrax, :rupert, keyword_init: true)

  def initialize(query:)
    @query = query.to_s.strip
  end

  def items
    @items ||= @query.blank? ? [] : build
  end

  private

  def build
    levels = InventoryWorkspace.levels(query: @query).reorder(:shopifyVariantId, :squareVariationId, :locationId).limit(LIMIT * 6).to_a
    groups = InventoryWorkspace.new(levels).rows.group_by { |row| [row[:level].source, row[:native_id]] }.first(LIMIT)
    variant_ids = groups.filter_map { |(source, id), _| id if source == 'shopify' }
    ctrax = ctrax_counts(variant_ids)
    rupert = rupert_counts(variant_ids)
    groups.map do |(source, native_id), rows|
      Item.new(row: rows.first, native_id: native_id, source: source,
        pools: rows.map { |row| Figure.new(place: row[:level].location&.name || 'Missing location', quantity: row[:promise], fresh: row[:fresh], row: row) },
        ctrax: ctrax.fetch(native_id, []), rupert: rupert.fetch(native_id, []))
    end
  end

  # C-Trax records name the Shopify variant they sell (website_variant_id); that exact ID is the only link used.
  def ctrax_counts(variant_ids)
    wanted = variant_ids.index_by { |id| id.to_s.split('/').last }
    CtraxStockSnapshot.includes(:location).to_a.select { |snapshot| snapshot.location&.active }.each_with_object({}) do |snapshot, out|
      fresh = snapshot.captured_at > SourceSyncStatus::FRESH_FOR.ago
      snapshot.records.each do |record|
        id = wanted[record['website_variant_id'].to_s] or next
        quantity = record['quantity'].to_s.match?(/\A-?\d+\z/) ? record['quantity'].to_i : nil
        (out[id] ||= []) << Figure.new(place: snapshot.location.name, quantity: quantity, fresh: fresh)
      end
    end
  end

  def rupert_counts(variant_ids)
    links = StockItemLink.where(platform: 'shopify', native_item_id: variant_ids).includes(:stock_site, stock_item: { balances: :stock_site })
    links.group_by(&:native_item_id).transform_values do |item_links|
      item_links.map(&:stock_item).uniq.flat_map(&:balances).uniq.select { |balance| balance.stock_site.active }
        .sort_by { |balance| balance.stock_site.name }
        .map { |balance| Figure.new(place: balance.stock_site.name, quantity: balance.on_hand, fresh: true) }
    end
  end
end
