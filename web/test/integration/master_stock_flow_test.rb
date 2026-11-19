# frozen_string_literal: true

require 'test_helper'

class MasterStockFlowTest < ActionDispatch::IntegrationTest
  include MasterStockHelper

  setup do
    master_stock_workspace!
    @tenant.update!(status: 'active') if @tenant.respond_to?(:status)
  end
  teardown { Current.reset }

  def sign_in(user)
    post login_path, params: { email: user.email, password: 'password123' }
  end

  test 'staff find an item, count it, receive and adjust on the phone flow, and see the ledger' do
    sign_in(@user)
    get master_stock_items_path, params: { q: 'GUM-10', all: 1 }
    assert_response :success
    assert_select 'a', text: 'Gummies 10 pack'
    assert_select 'span.pill-fern', 'Exact code match'

    get new_master_stock_movement_path(kind: 'count', item_id: @item.id, site_id: @site.id)
    assert_response :success
    assert_select 'input[name="movement[quantity]"][inputmode="numeric"]'
    token = css_select('input[name="request_token"]').first['value']
    params = { request_token: token, movement: { kind: 'count', item_id: @item.id, site_id: @site.id, quantity: '7' } }
    post master_stock_movements_path, params: params
    assert_redirected_to master_stock_items_path(site_id: @site.id)
    assert_equal 'Count: Gummies 10 pack at Main store is now 7.', flash[:notice]
    post master_stock_movements_path, params: params
    assert_match 'nothing was added twice', flash[:notice]

    post master_stock_movements_path, params: { request_token: SecureRandom.uuid, movement: { kind: 'adjust', item_id: @item.id, site_id: @site.id, quantity: '-9', reason: 'theft' } }
    assert_response :unprocessable_entity
    assert_select '[role=alert]', /Rupert shows 7 on hand/

    get master_stock_movements_path
    assert_response :success
    assert_select 'td', text: /Gummies 10 pack/, count: 1
    get master_stock_movements_path(format: :csv)
    assert_equal '7', CSV.parse(response.body, headers: true).first['After']
  end

  test 'the push preview renders exact proposed writes without contacting a platform' do
    StockItemLink.create!(stock_item: @item, stock_site: @site, platform: 'shopify', native_item_id: @variant.id, linked_by: @admin.email)
    shopify_snapshot!(on_hand: 12)
    record('count', 10)
    sign_in(@user)
    get master_stock_push_preview_path(site_id: @site.id, platform: 'shopify')
    assert_response :success
    assert_select 'p', text: 'Set Shopify on hand from 12 to 10.'
    assert_select 'pre', /changeFromQuantity/
    assert_not_requested :any, /myshopify|cannatrax|squareup/
  end

  test 'setup needs settings write; readers cannot record' do
    sign_in(@user)
    get master_stock_setup_path
    assert_response :success
    post master_stock_sites_path, params: { stock_site: { name: 'Back room' } }
    assert_response :redirect
    refute StockSite.exists?(name: 'Back room')

    delete logout_path
    sign_in(@admin)
    post master_stock_sites_path, params: { stock_site: { name: 'Back room', ctrax_location_id: @ctrax_location.id } }
    assert_match 'C-Trax location', flash[:alert], 'a C-Trax store can belong to one site only'
    post master_stock_sites_path, params: { stock_site: { name: 'Back room' } }
    assert StockSite.exists?(name: 'Back room')
    post master_stock_links_path, params: { item_id: @item.id, site_id: @site.id, platform: 'shopify', native_item_id: '501' }
    assert_equal @variant.id, StockItemLink.find_by!(stock_item: @item, platform: 'shopify').native_item_id

    reader = User.create!(email: "reader-#{SecureRandom.hex(3)}@example.com", password: 'password123', role: 'reader', tenant: @tenant)
    delete logout_path
    sign_in(reader)
    get master_stock_items_path
    assert_response :success
    get new_master_stock_movement_path(kind: 'count', item_id: @item.id, site_id: @site.id)
    assert_response :redirect
    post master_stock_movements_path, params: { request_token: SecureRandom.uuid, movement: { kind: 'count', item_id: @item.id, site_id: @site.id, quantity: '1' } }
    assert_equal 0, StockLedgerEntry.count
  end
end
