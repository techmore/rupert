# frozen_string_literal: true

require 'test_helper'

class MasterStockPushPreviewTest < ActiveSupport::TestCase
  include MasterStockHelper

  setup do
    master_stock_workspace!
    StockItemLink.create!(stock_item: @item, stock_site: @site, platform: 'shopify', native_item_id: @variant.id, linked_by: @admin.email)
    StockItemLink.create!(stock_item: @item, stock_site: @site, platform: 'ctrax', native_item_id: '3001', linked_by: @admin.email)
  end
  teardown { Current.reset }

  def preview(platform) = MasterStock::PushPreview.new(site: @site, platform: platform)

  test 'shopify rows propose a guarded on-hand set and the exact request, sending nothing' do
    shopify_snapshot!(on_hand: 12)
    record('count', 10)
    row = preview('shopify').rows.sole
    assert_equal ['change', 12, 10, -2], [row.status, row.observed, row.target, row.change]
    assert_equal 'Set Shopify on hand from 12 to 10.', row.action
    input = row.payload.fetch('input')
    assert_equal 'on_hand', input['name']
    assert_equal({ 'inventoryItemId' => 'gid://shopify/InventoryItem/901', 'locationId' => 'gid://shopify/Location/11',
                   'quantity' => 10, 'changeFromQuantity' => 12 }, input['quantities'].sole)
    assert_equal({ change: 1, blocked: 0, in_sync: 0, units_down: 2, units_up: 0 }, preview('shopify').summary)
  end

  test 'rows are blocked without a Rupert count, with a stale read, or when unknown' do
    shopify_snapshot!(on_hand: 4, at: 2.hours.ago)
    row = preview('shopify').rows.sole
    assert_equal 'blocked', row.status
    assert_includes row.reasons, 'Count this item in Rupert first.'
    assert row.reasons.any? { |reason| reason.include?('more than an hour ago') }
    assert_nil row.payload

    record('count', 4)
    ShopifyStockSnapshot.find_by!(location: @shopify_location).update!(captured_at: 1.minute.ago)
    assert_equal 'in_sync', preview('shopify').rows.sole.status
  end

  test 'c-trax decreases become a marked remove and increases stay manual' do
    ctrax_snapshot!([{ 'id' => '3001', 'quantity' => '9', 'manage_stock' => true }])
    record('count', 6)
    row = preview('ctrax').rows.sole
    assert_equal 'Remove 3 in C-Trax (9 → 6).', row.action
    assert_equal '/api/v1/stores/7/productVariants/3001/inventoryAdjustments', row.payload['path']
    assert_equal({ 'action' => 'remove', 'quantity' => 3, 'reason' => 'other' }, row.payload['body'].slice('action', 'quantity', 'reason'))

    record('receive', 5)
    row = preview('ctrax').rows.sole
    assert_equal 'blocked', row.status
    assert row.reasons.any? { |reason| reason.include?('Enter +2 in C-Trax by hand') }
  end

  test 'untracked or fractional c-trax stock and unmapped platforms are blocked' do
    ctrax_snapshot!([{ 'id' => '3001', 'quantity' => '2.5', 'manage_stock' => false }])
    record('count', 2)
    reasons = preview('ctrax').rows.sole.reasons
    assert_includes reasons, 'C-Trax does not track stock for this variant.'
    assert_includes reasons, 'C-Trax stock is not a whole number.'
    assert_match 'no Square location', preview('square').platform_blocker
  end
end
