# frozen_string_literal: true

require 'test_helper'

class MasterStockImporterTest < ActiveSupport::TestCase
  include MasterStockHelper

  setup { master_stock_workspace! }
  teardown { Current.reset }

  def import(**options) = MasterStock::Importer.new(actor: @admin).call(site: @site, platform: 'ctrax', token: SecureRandom.hex(8), **options)

  test 'c-trax import links exact native items, adds exact Shopify links and never matches by SKU' do
    ctrax_snapshot!([
      { 'id' => '3001', 'name' => 'Gummies 10 pack', 'sku' => 'GUM-10', 'quantity' => '9', 'manage_stock' => true, 'website_variant_id' => '501' },
      { 'id' => '3002', 'name' => 'Tincture', 'sku' => 'GUM-10', 'quantity' => '-1', 'manage_stock' => true },
      { 'id' => '3003', 'name' => 'Untracked sticker', 'quantity' => nil, 'manage_stock' => false }
    ])
    result = import(seed_balances: true)
    assert_equal [2, 1, 1, 1], [result.created, result.shopify_links, result.opened, result.uncounted]

    gummies = StockItemLink.find_by!(platform: 'ctrax', native_item_id: '3001').stock_item
    assert_equal @variant.id, gummies.links.find_by!(platform: 'shopify').native_item_id
    tincture = StockItemLink.find_by!(platform: 'ctrax', native_item_id: '3002').stock_item
    refute tincture.links.exists?(platform: 'shopify'), 'a shared SKU must not create a Shopify link'
    assert_equal 9, StockBalance.find_by!(stock_item: gummies).on_hand
    refute StockBalance.exists?(stock_item: tincture), 'negative stock needs a physical count'
    assert_match 'Opening count from C-Trax read', gummies.ledger_entries.sole.reference

    again = import
    assert_equal [0, 2], [again.created, again.skipped]
  end

  test 'seeding needs a fresh read and setup needs settings write' do
    ctrax_snapshot!([{ 'id' => '3001', 'quantity' => '9', 'manage_stock' => true }], at: 3.hours.ago)
    assert_match 'last hour', assert_raises(MasterStock::Error) { import(seed_balances: true) }.message
    assert_raises(MasterStock::Error) { MasterStock::Importer.new(actor: @user) }
    assert_equal 0, StockItemLink.count
  end
end
