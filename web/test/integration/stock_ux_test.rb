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
end
