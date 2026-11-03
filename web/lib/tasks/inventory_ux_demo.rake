# frozen_string_literal: true

# Fictional stock data for reviewing Rupert's inventory and sync screens
# (docs/ux/inventory-ux-loop.md). It adds to the "Juniper & Pine Market" demo
# workspace (run rupert:app_review_demo first): a larger catalog with sizes and
# scents, three shops and a stockroom, Shopify and C-Trax stock reads (one
# fresh, one stale), sync failures, mismatches between platforms, transfers,
# reservations and a Rupert stock ledger with a few weeks of movements.
#
#   bin/rails rupert:inventory_ux_demo
#
# Development and test only. Every name, SKU, barcode and native ID is made up:
# barcodes use the 200–299 in-store range and native IDs start at 9100000.
module InventoryUxDemo
  SEED = 20_261_102
  CTRAX_ORIGIN = 'https://demo-store.ctrax.example'

  # product title, type, variant titles, base price in cents
  CATALOG = [
    ['Field Guide Tee', 'Apparel', %w[S M L XL 2XL], 28_00],
    ['Trail Map Crew Socks', 'Apparel', ['S/M', 'L/XL'], 14_00],
    ['Canvas Market Tote', 'Bags', %w[Natural Black], 22_00],
    ['Hand-poured Candle, Cedar', 'Candles', ['4 oz tin', '8 oz jar', '16 oz jar'], 16_00],
    ['Hand-poured Candle, Sea Salt', 'Candles', ['4 oz tin', '8 oz jar'], 16_00],
    ['Hand-poured Candle, Ember', 'Candles', ['4 oz tin', '8 oz jar'], 16_00],
    ['Single Origin Coffee, Highland', 'Coffee & tea', ['12 oz whole bean', '12 oz ground', '2 lb whole bean'], 17_00],
    ['Single Origin Coffee, Valley', 'Coffee & tea', ['12 oz whole bean', '12 oz ground'], 17_00],
    ['Loose Leaf Tea Sampler', 'Coffee & tea', ['6 tins'], 32_00],
    ['Enamel Pin', 'Gifts', ['Fern', 'Mushroom', 'Moon', 'Canoe', 'Pine cone'], 10_00],
    ['Jigsaw Puzzle, Lake at Dusk', 'Games', ['500 pieces', '1000 pieces'], 24_00],
    ['Stoneware Pour-over', 'Kitchen', ['Oat', 'Charcoal'], 38_00],
    ['Beeswax Food Wraps', 'Kitchen', ['Set of 3'], 18_00],
    ['Goat Milk Soap', 'Bath & body', ['Unscented', 'Oatmeal', 'Lavender', 'Mint'], 9_00],
    ['Hand Cream', 'Bath & body', ['Rose', 'Unscented', 'Citrus'], 15_00],
    ['Letterpress Card', 'Paper goods', ['Birthday', 'Thank you', 'Congratulations', 'Sympathy'], 6_50],
    ['Vinyl Sticker', 'Paper goods', ['Trail', 'Wave', 'Peak'], 4_00],
    ['Linen Napkins', 'Kitchen', ['Set of 4, Sage', 'Set of 4, Clay'], 30_00]
  ].freeze

  module_function

  def run!(now: Time.current.change(usec: 0))
    raise 'The inventory UX demo is for development and test only.' if Rails.env.production?

    tenant = Tenant.find_by(subdomain: AppReviewDemo::SUBDOMAIN) or raise 'Run rupert:app_review_demo first.'
    user = User.find_by!(email: AppReviewDemo::EMAIL, tenant: tenant)
    people = User.where(tenant: tenant, email: AppReviewDemo::PEOPLE.map { |p| p[:email] }).index_by { |u| u.email.split('.').first }
    rng = Random.new(SEED)
    Current.set(tenant: tenant, user: user) do
      wipe_master_stock!
      locations = ensure_locations!(now)
      variants = ensure_catalog!(locations, rng, now)
      ensure_shopify_reads!(locations, variants, now)
      ensure_ctrax_reads!(locations, variants, rng, now)
      ensure_sync_history!(variants, rng, now)
      ensure_alerts!(variants, locations)
      ensure_requests!(locations, variants, user)
      sites = ensure_master_stock!(locations, user, people, rng, now)
      DataCache.bump! if defined?(DataCache)
      { variants: variants.size, sites: sites.size, movements: StockLedgerEntry.count }
    end
  end

  def wipe_master_stock!
    [StockLedgerEntry, StockBalance, StockItemLink, StockItem, StockSite].each { |model| model.where(tenant_id: Current.tenant_id).delete_all }
  end

  def ensure_locations!(now)
    shopify = ->(key, name, primary: false) do
      Location.find_or_initialize_by(source: 'shopify', externalId: "#{AppReviewDemo::KEY}-#{key}").tap do |location|
        location.update!(name: name, active: true, primary_location: primary, timezone: Time.zone.tzinfo.name, syncedAt: now)
      end
    end
    ctrax = ->(store, name) do
      Location.find_or_initialize_by(source: 'ctrax', externalId: "demo-store.ctrax.example/#{store}").tap do |location|
        location.update!(name: name, active: true, timezone: Time.zone.tzinfo.name, syncedAt: now)
      end
    end
    square = Location.find_or_initialize_by(source: 'square', externalId: 'DEMOMARKET01')
    square.update!(name: 'Saturday market', active: false, timezone: Time.zone.tzinfo.name, syncedAt: now - 40.days)
    {
      shop: shopify.call('shop', 'Main Street Shop', primary: true),
      back: shopify.call('back-room', 'Back Stockroom'),
      river: shopify.call('riverside', 'Riverside Shop'),
      ctrax_main: ctrax.call('101', 'Main Street (C-Trax)'),
      ctrax_river: ctrax.call('102', 'Riverside (C-Trax)'),
      square: square
    }
  end

  def ensure_catalog!(locations, rng, now)
    index = 0
    CATALOG.each_with_index.flat_map do |(title, type, variant_titles, price), product_index|
      product = ShopifyProduct.find_or_initialize_by(id: "gid://shopify/Product/#{9_100_000 + product_index}")
      product.update!(title: title, handle: title.parameterize, vendor: AppReviewDemo::NAME, productType: type, status: 'ACTIVE',
        catalog_present: true, catalog_read_at: now, publishedAt: now - 120.days, syncedAt: now)
      variant_titles.map do |variant_title|
        index += 1
        id = 9_200_000 + index
        # Stickers and cards carry no SKU, like many real shops; one SKU is shared by two variants.
        sku = if type == 'Paper goods' then nil
        elsif title.start_with?('Linen Napkins') then 'JP-NAP-4'
        else format('JP-%04d', 2000 + index)
        end
        variant = ShopifyVariant.find_or_initialize_by(id: "gid://shopify/ProductVariant/#{id}")
        variant.update!(productId: product.id, title: variant_title, sku: sku, price: (price + (variant_titles.index(variant_title) * 4_00)) / 100.0,
          barcode: (index % 9).zero? ? nil : AppReviewDemo.barcode(500 + index), inventoryItemId: "gid://shopify/InventoryItem/#{9_300_000 + index}",
          tracked: true, catalog_present: true, catalog_read_at: now - 8.minutes, syncedAt: now - 8.minutes)
        stock = {
          locations[:shop] => [0, 0, 1, 2, 3, 4, 6, 8, 12, 15, 22].sample(random: rng),
          locations[:back] => [0, 0, 6, 12, 18, 24, 36].sample(random: rng),
          locations[:river] => [-2, 0, 1, 3, 5, 7, 10].sample(random: rng)
        }
        stock.each do |location, quantity|
          level = InventoryLevel.find_or_initialize_by(source: 'shopify', locationId: location.id, shopifyVariantId: variant.id)
          stale = location == locations[:river]
          level.update!(quantity: quantity, available: quantity, sourceQuantity: quantity, updatedAt: stale ? now - 3.days : now - rng.rand(5..50).minutes)
        end
        variant.update!(inventoryQuantity: stock.values.sum)
        { variant: variant, product: product, stock: stock }
      end
    end
  end

  # One Shopify read eight minutes ago covered Main Street and the stockroom (the same moment as
  # the catalog read, which Store comparison requires); Riverside's last good read is three days old.
  def ensure_shopify_reads!(locations, variants, now)
    { shop: now - 8.minutes, back: now - 8.minutes, river: now - 3.days }.each do |key, at|
      location = locations.fetch(key)
      records = variants.map do |row|
        on_hand = row[:stock][location]
        committed = on_hand.positive? && (row[:variant].id.hash % 5).zero? ? 1 : 0
        { 'id' => row[:variant].id, 'inventory_item_id' => row[:variant].inventoryItemId, 'on_hand' => on_hand,
          'available' => on_hand - committed, 'committed' => committed }
      end
      # The App Store demo's original twelve items are in the same read.
      original = ShopifyVariant.where('"productId" LIKE ?', "#{AppReviewDemo::KEY}-product-%").select(:id)
      InventoryLevel.where(source: 'shopify', locationId: location.id, shopifyVariantId: original).each do |level|
        ShopifyVariant.where(id: level.shopifyVariantId).update_all(catalog_read_at: at) unless key == :river
        records << { 'id' => level.shopifyVariantId, 'on_hand' => level.quantity, 'available' => level.available, 'committed' => 0 }
      end
      snapshot = ShopifyStockSnapshot.find_or_initialize_by(location: location)
      snapshot.update!(shop_domain: 'juniper-pine-demo.myshopify.com', captured_at: at, records_json: records)
    end
  end

  # C-Trax mostly agrees with Shopify, with the usual drift: a few counts off by one or two,
  # a negative, a fractional bulk unit, an untracked item and items only C-Trax sells.
  def ensure_ctrax_reads!(locations, variants, rng, now)
    { ctrax_main: [:shop, '101', now - 35.minutes], ctrax_river: [:river, '102', now - 2.days] }.each do |key, (shopify_key, store, at)|
      records = variants.each_with_index.map do |row, i|
        quantity = row[:stock][locations[shopify_key]]
        quantity += [-2, -1, 1, 3].sample(random: rng) if (i % 7) == 3
        quantity = -1 if i == 11
        variant = row[:variant]
        {
          'id' => (7_000_000 + (store.to_i * 1000) + i).to_s, 'sku' => variant.sku, 'barcode' => variant.barcode,
          'name' => "#{row[:product].title} – #{variant.title}", 'product_name' => row[:product].title, 'category' => row[:product].productType,
          'quantity' => i == 19 ? '2.5' : quantity.to_s, 'manage_stock' => i != 23,
          # Most C-Trax items carry their Shopify variant; a few were never linked in C-Trax.
          'website_variant_id' => (i % 10) == 6 ? nil : variant.id.split('/').last,
          'price_cents' => (variant.price * 100).round, 'listed' => true
        }
      end
      [['Gift wrap', 'Service', nil], ['Sample candle, Cedar', 'Candles', '3'], ['Bulk lavender (oz)', 'Bath & body', '14.25']].each_with_index do |(name, category, quantity), extra|
        records << { 'id' => (7_000_900 + (store.to_i * 1000) + extra).to_s, 'name' => name, 'product_name' => name, 'category' => category,
                     'quantity' => quantity, 'manage_stock' => !quantity.nil?, 'listed' => true }
      end
      snapshot = CtraxStockSnapshot.find_or_initialize_by(location: locations.fetch(key))
      snapshot.update!(api_origin: CTRAX_ORIGIN, store_id: store, captured_at: at, records_json: records)
    end
  end

  def ensure_sync_history!(variants, rng, now)
    SyncRun.where(tenant_id: Current.tenant_id).delete_all
    [
      [now - 8.minutes, 'scheduled', 'shopify', 'success', nil],
      [now - 68.minutes, 'scheduled', 'shopify', 'success', nil],
      [now - 128.minutes, 'scheduled', 'shopify', 'failed', 'Shopify throttled the request (HTTP 429). The next scheduled sync retries.'],
      [now - 1.day, 'manual', 'all', 'success', nil],
      [now - 3.days, 'scheduled', 'shopify', 'failed', 'Riverside Shop: location not found in the Shopify response; kept the previous read.']
    ].each do |at, mode, source, status, error|
      SyncRun.create!(startedAt: at, finishedAt: at + 40.seconds, mode: mode, source: source, status: status, error: error,
        actor: mode == 'manual' ? AppReviewDemo::EMAIL : 'scheduler')
    end
    SyncAttempt.where(tenant_id: Current.tenant_id).delete_all
    [
      ['stock', 'succeeded', nil, now - 35.minutes],
      ['stock', 'failed', 'credentials', now - 95.minutes],
      ['stock', 'failed', 'timeout', now - 2.days],
      ['sales', 'succeeded', nil, now - 5.hours]
    ].each do |operation, status, category, at|
      SyncAttempt.create!(source: 'ctrax', operation: operation, status: status, error_category: category, queued_at: at, started_at: at, finished_at: at + 20.seconds)
    end
    InventoryMovement.where(tenant_id: Current.tenant_id).delete_all
    variants.sample(40, random: rng).each_with_index do |row, i|
      before = row[:stock].values.first
      delta = [-3, -2, -1, -1, 1, 2, 6].sample(random: rng)
      InventoryMovement.create!(source: 'shopify', direction: delta.negative? ? 'out' : 'in', delta: delta, quantityBefore: before,
        quantityAfter: before + delta, sku: row[:variant].sku, shopifyVariantId: row[:variant].id, actor: 'scheduler',
        reason: delta.negative? ? 'Sold online' : 'Restocked in Shopify admin', createdAt: now - (i * 47).minutes)
    end
  end

  def ensure_alerts!(variants, locations)
    variants.each do |row|
      total = row[:stock].values.sum
      next unless total <= 3 && row[:variant].sku

      alert = StockAlert.find_or_initialize_by(sku: row[:variant].sku, status: 'open')
      alert.update!(shopifyVariantId: row[:variant].id, quantity: total, threshold: 5,
        note: total <= 0 ? 'Sold out everywhere' : "Low: #{row[:stock][locations[:shop]]} on the Main Street floor")
    end
  end

  def ensure_requests!(locations, variants, user)
    StockRequest.where(tenant_id: Current.tenant_id).delete_all
    StockReservation.where(tenant_id: Current.tenant_id).delete_all
    pool = ->(location, variant) { StockReservationPool.for_level!(InventoryLevel.find_by!(source: 'shopify', locationId: location.id, shopifyVariantId: variant.id)) }
    stocked = variants.select { |row| row[:stock][locations[:back]] >= 6 }.first(3)
    request = ->(**attrs) { StockRequest.new(**attrs).tap { |r| r.workflow_checked = true }.save! }
    stocked.each_with_index do |row, i|
      request.call(request_kind: 'transfer', source_pool: pool.call(locations[:back], row[:variant]), destination_pool: pool.call(locations[:shop], row[:variant]),
        quantity: 4 + i, reference: "Restock front table #{i + 1}", status: %w[allocated dispatched pending][i], created_by: user.email,
        source_location_external_id: locations[:back].externalId, destination_location_external_id: locations[:shop].externalId)
    end
    out = variants.find { |row| row[:stock].values.sum <= 0 } || variants.first
    request.call(request_kind: 'backorder', source_pool: pool.call(locations[:shop], out[:variant]), quantity: 2,
      reference: 'Customer special order (phone)', status: 'pending', due_on: Date.current + 5, created_by: user.email,
      source_location_external_id: locations[:shop].externalId)
    level = InventoryLevel.find_by!(source: 'shopify', locationId: locations[:shop].id, shopifyVariantId: stocked.first[:variant].id)
    StockReservationService.reserve(inventory_level_id: level.id, actor: user.email,
      attributes: { quantity: 1, reference: 'Held for pickup, order #1043', request_token: SecureRandom.uuid, expires_at: 2.days.from_now })
  end

  # Three Rupert sites. Main Street was imported from C-Trax with opening counts and has two
  # weeks of staff movements; Riverside is linked but only partly counted; the stockroom is Shopify only.
  def ensure_master_stock!(locations, user, people, rng, now)
    main = StockSite.create!(name: 'Main Street', shopify_location_id: locations[:shop].id, ctrax_location_id: locations[:ctrax_main].id)
    river = StockSite.create!(name: 'Riverside', shopify_location_id: locations[:river].id, ctrax_location_id: locations[:ctrax_river].id)
    back = StockSite.create!(name: 'Back stockroom', shopify_location_id: locations[:back].id)
    MasterStock::Importer.new(actor: user).call(site: main, platform: 'ctrax', token: "demo-#{SecureRandom.hex(4)}", seed_balances: true)
    StockLedgerEntry.where(tenant_id: Current.tenant_id).update_all(created_at: now - 15.days)
    StockBalance.where(tenant_id: Current.tenant_id).update_all(counted_at: now - 15.days)

    river_records = CtraxStockSnapshot.find_by!(location: locations[:ctrax_river]).records.index_by { |r| r['website_variant_id'] }
    StockItem.where(tenant_id: Current.tenant_id).includes(:links).find_each do |item|
      shopify = item.links.find { |l| l.platform == 'shopify' }&.native_item_id
      next unless shopify

      StockItemLink.create!(stock_item: item, stock_site: river, platform: 'shopify', native_item_id: shopify, match_source: 'manual', linked_by: user.email)
      if (record = river_records[shopify.split('/').last])
        StockItemLink.create!(stock_item: item, stock_site: river, platform: 'ctrax', native_item_id: record['id'], match_source: 'manual', linked_by: user.email)
      end
      StockItemLink.create!(stock_item: item, stock_site: back, platform: 'shopify', native_item_id: shopify, match_source: 'manual', linked_by: user.email)
    end

    actors = [user, people['maya'], people['theo']].compact
    items = StockItem.where(tenant_id: Current.tenant_id).joins(:balances).distinct.order(:id).to_a
    plan = []
    items.each_with_index do |item, i|
      plan << [14 - (i % 12), :receive, main, item, [6, 12, 24].sample(random: rng)] if (i % 4).zero?
      plan << [10 - (i % 9), :adjust, main, item, -1] if (i % 9) == 2
      plan << [6 - (i % 5), :count, main, item, nil] if (i % 3) == 1
      plan << [3, :count, back, item, [6, 12, 18, 24].sample(random: rng)] if (i % 2).zero?
      plan << [2, :transfer, back, item, 2] if (i % 6).zero?
      plan << [1, :count, river, item, [0, 2, 4, 5, 8].sample(random: rng)] if (i % 3).zero?
    end
    plan.sort_by(&:first).reverse.each_with_index do |(days_ago, kind, site, item, quantity), i|
      actor = actors[i % actors.size]
      ledger = MasterStock::Ledger.new(actor: actor)
      balance = StockBalance.find_by(stock_item: item, stock_site: site)
      token = SecureRandom.uuid
      result = case kind
      when :receive then ledger.record(kind: 'receive', item: item, site: site, quantity: quantity, token: token, reference: "PO-#{4100 + i}")
      when :adjust
        next unless balance&.on_hand&.positive?

        ledger.record(kind: 'adjust', item: item, site: site, quantity: quantity, token: token, reason: %w[damaged sample theft].sample(random: rng))
      when :count
        quantity ||= [balance&.on_hand.to_i + [-2, -1, 0, 0, 1].sample(random: rng), 0].max
        ledger.record(kind: 'count', item: item, site: site, quantity: quantity, token: token)
      when :transfer
        next unless balance && balance.on_hand >= quantity

        ledger.record(kind: 'transfer', item: item, site: site, destination_site: main, quantity: quantity, token: token, reference: "Slip #{300 + i}")
      end
      at = now - days_ago.days - rng.rand(0..480).minutes
      StockLedgerEntry.where(id: result.entries.map(&:id)).update_all(created_at: at)
      StockBalance.where(stock_item: item, stock_site: site).where.not(counted_at: nil).update_all(counted_at: at) if kind == :count
    end
    [main, river, back]
  end
end

namespace :rupert do
  desc 'Add fictional multi-site stock, sync history and Rupert stock to the app review demo (development only)'
  task inventory_ux_demo: :environment do
    result = InventoryUxDemo.run!
    puts "Inventory UX demo ready: #{result[:variants]} variants, #{result[:sites]} Rupert sites, #{result[:movements]} ledger rows."
  end
end
