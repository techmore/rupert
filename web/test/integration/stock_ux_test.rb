# frozen_string_literal: true

require 'test_helper'

# What staff see on the stock and sync screens (docs/ux/inventory-ux-loop.md).
class StockUxTest < ActionDispatch::IntegrationTest
  include MasterStockHelper

  setup { master_stock_workspace! }
  teardown { Current.reset }

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def link_shopify!
    StockItemLink.create!(stock_item: @item, stock_site: @site, platform: 'shopify', native_item_id: @variant.id, linked_by: @admin.email)
  end

  test 'the stock list shows what each platform holds beside Rupert, in words' do
    link_shopify!
    shopify_snapshot!(on_hand: 9)
    record('count', 7)
    sign_in(@user)
    get master_stock_items_path(site_id: @site.id)
    assert_response :success
    assert_select '.stock-reading[data-platform=shopify]', text: 'Shopify 9 · 2 more'
    assert_select '.stock-qty', text: '7'
    assert_select 'a.stock-action', text: 'Transfer'

    ShopifyStockSnapshot.find_by!(location: @shopify_location).update!(captured_at: 3.hours.ago,
      records_json: [{ 'id' => @variant.id, 'inventory_item_id' => @variant.inventoryItemId, 'on_hand' => 7, 'available' => 7, 'committed' => 0 }])
    get master_stock_items_path(site_id: @site.id)
    assert_select '.stock-reading[data-platform=shopify]', text: 'Shopify 7 · matches · 3 h old'
  end

  test 'the stock list opens on the shop floor first, then on the last site used' do
    StockSite.create!(name: 'A stockroom')
    @shopify_location.update!(primary_location: true)
    sign_in(@user)
    get master_stock_items_path
    assert_select '.page-subtitle', /at Main store\./

    get master_stock_items_path(site_id: @other_site.id)
    get master_stock_items_path
    assert_select '.page-subtitle', /at Second store\./
  end

  test 'a count hides Rupert’s number while counting and reports the difference after' do
    record('count', 7)
    sign_in(@user)
    get new_master_stock_movement_path(kind: 'count', item_id: @item.id, site_id: @site.id)
    assert_select 'p', text: /stays hidden until you save/
    assert_select '.stat-value', count: 0

    post master_stock_movements_path, params: { request_token: SecureRandom.uuid, movement: { kind: 'count', item_id: @item.id, site_id: @site.id, quantity: '5' } }
    assert_equal 'Count: Gummies 10 pack at Main store is now 5. Rupert had 7 (2 fewer counted).', flash[:notice]

    get new_master_stock_movement_path(kind: 'receive', item_id: @item.id, site_id: @site.id)
    assert_select '.stat-value', text: '5'
  end

  test 'the push preview lists the biggest changes first and flags large ones for a recount' do
    link_shopify!
    shopify_snapshot!(on_hand: 2)
    record('count', 30)
    sign_in(@user)
    get master_stock_push_preview_path(site_id: @site.id, platform: 'shopify')
    assert_select 'tr.preview-row-large .pill-rose', text: 'Large change: recount first'
    assert_select 'nav[aria-label=Show] a', text: 'Change 1'
    assert_select '.callout-title', /Preview only/
  end

  test 'the ledger names people and searches by item' do
    record('count', 7)
    @user.update!(name: 'Robin Reyes')
    sign_in(@user)
    get master_stock_movements_path(q: 'GUM-10')
    assert_select 'td p', text: 'Robin Reyes'
    assert_select 'td span', text: 'Set'
    get master_stock_movements_path(q: 'nothing like this')
    assert_select 'td.empty-row', /No movements match/
  end

  test 'store comparison opens on the pair mapped as one Rupert site' do
    other_shopify = Location.create!(source: 'shopify', externalId: 'gid://shopify/Location/12', name: 'Annex (Shopify)', active: true)
    other_ctrax = Location.create!(source: 'ctrax', externalId: 'store.api.cannatrax.net/8', name: 'Annex (C-Trax)', active: true)
    shopify_snapshot!(on_hand: 4)
    ShopifyStockSnapshot.create!(location: other_shopify, shop_domain: 'example.myshopify.com', captured_at: 5.minutes.ago,
      records_json: [{ 'id' => @variant.id, 'on_hand' => 1, 'available' => 1, 'committed' => 0 }])
    ctrax_snapshot!([{ 'id' => '3001', 'quantity' => '4', 'manage_stock' => true }])
    CtraxStockSnapshot.create!(location: other_ctrax, api_origin: 'https://store.api.cannatrax.net', store_id: '8', captured_at: 5.minutes.ago, records_json: [])
    sign_in(@admin)
    get stock_comparison_path
    assert_response :success
    assert_select '#shopify_location_id option[selected]', text: 'Main (Shopify)'
    assert_select '#ctrax_location_id option[selected]', text: 'Main (C-Trax)'
    assert_select 'p[role=status]', /mapped together as the Rupert site Main store/
  end

  test 'the sync page shows each store’s stock read age and the latest C-Trax failure with its fix' do
    ctrax_snapshot!([], at: 3.hours.ago)
    SyncAttempt.create!(source: 'ctrax', operation: 'stock', status: 'failed', error_category: 'credentials', queued_at: 20.minutes.ago)
    sign_in(@admin)
    get syncs_path
    assert_response :success
    assert_select '[data-source=ctrax] li', text: /Main \(C-Trax\)\s*3 h ago · old/
    assert_select '[data-source=ctrax] p.text-rose', /Credentials rejected · 20 min ago/
    assert_select '[data-source=ctrax] p', /Check this connection’s saved login/
  end

  test 'scan-to-count mode opens the count for an exact scan and returns to an empty search' do
    sign_in(@user)
    get master_stock_items_path(site_id: @site.id, scan_mode: 'count')
    get master_stock_items_path(site_id: @site.id, q: 'GUM-10', all: 1)
    assert_redirected_to new_master_stock_movement_path(kind: 'count', item_id: @item.id, site_id: @site.id, scan: 1)
    follow_redirect!
    assert_select 'input[name=scan][value="1"]'

    post master_stock_movements_path, params: { scan: '1', return_q: 'GUM-10', request_token: SecureRandom.uuid,
                                                movement: { kind: 'count', item_id: @item.id, site_id: @site.id, quantity: '4' } }
    assert_redirected_to master_stock_items_path(site_id: @site.id)
  end

  test 'a barcode scanned into the quantity box is refused, and a far-off count asks for a recount' do
    record('count', 3)
    sign_in(@user)
    count = ->(quantity, **extra) { post master_stock_movements_path, params: { request_token: 'same-token', movement: { kind: 'count', item_id: @item.id, site_id: @site.id, quantity: quantity } }.merge(extra) }
    count.call('0012345678905')
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /looks like a scanned barcode/
    assert_select 'input[name="movement[quantity]"][value="0012345678905"]', count: 0

    count.call('40')
    assert_response :unprocessable_entity
    assert_select '.callout-title', 'Check this count'
    assert_select '[role=alert] p', /40 is 37 more than Rupert expects/
    assert_select 'input[name=confirm_variance][value="1"]'
    assert_equal 3, StockBalance.find_by!(stock_item: @item, stock_site: @site).on_hand

    count.call('40', confirm_variance: '1')
    assert_equal 40, StockBalance.find_by!(stock_item: @item, stock_site: @site).on_hand
  end

  test 'inventory search finds items by product name and answers with every source at a glance' do
    level = InventoryLevel.create!(source: 'shopify', locationId: @shopify_location.id, shopifyVariantId: @variant.id, quantity: 6, available: 6, updatedAt: Time.current)
    link_shopify!
    record('count', 5)
    ctrax_snapshot!([{ 'id' => '3001', 'quantity' => '4', 'manage_stock' => true, 'website_variant_id' => '501' }])
    sign_in(@admin)
    get inventory_index_path(q: 'gummies 10')
    assert_response :success
    assert_select '.glance-item', 1
    assert_select '.glance-group', text: /Shopify, can sell\s+Main \(Shopify\)\s+6/
    assert_select '.glance-group', text: /C-Trax stock\s+Main \(C-Trax\)\s+4/
    assert_select '.glance-group', text: /Rupert stock\s+Main store\s+5/
    assert_select '.stock-item-meta', text: 'GUM-10'
    assert level
  end

  test 'the register explains why it is empty when every item lacks a website image' do
    ctrax_snapshot!([{ 'id' => '3001', 'name' => 'Gummies', 'quantity' => '4', 'manage_stock' => true, 'price_cents' => 1000 }])
    sign_in(@admin)
    get ctrax_pos_path(location_id: @ctrax_location.id)
    assert_response :success
    assert_select '.empty-state-title', '1 product hidden until linked to a website image'
  end

  test 'counts and movements name the product, and a product page keeps Stock lit in the rail' do
    count = InventoryCount.create!(countedAt: Time.current, locationId: @shopify_location.id, createdBy: @admin.email)
    item = InventoryCountItem.create!(count: count, sku: 'GUM-10', quantity: 3, shopifyVariantId: @variant.id)
    assert_equal 'Gummies · 10 pack', item.inventory_title
    InventoryMovement.create!(source: 'shopify', direction: 'out', delta: -1, quantityBefore: 4, quantityAfter: 3,
      shopifyVariantId: @variant.id, sku: nil, actor: 'scheduler', reason: 'Sold online')

    sign_in(@admin)
    get movements_inventory_index_path
    assert_select 'td p.font-medium', text: 'Gummies'
    assert_select 'td p.text-xs', text: '10 pack'
    get shopify_variant_path(@variant.id)
    assert_select 'nav[aria-label="Module areas"] a[aria-label="Stock"][aria-current="page"]'
    get inventory_counts_path
    assert_select '[data-count-kinds]', /never change a number/
  end
end
