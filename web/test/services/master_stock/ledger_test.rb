# frozen_string_literal: true

require 'test_helper'

class MasterStockLedgerTest < ActiveSupport::TestCase
  include MasterStockHelper

  setup { master_stock_workspace! }
  teardown { Current.reset }

  test 'the first entry must be a count; later entries move the balance and keep before and after' do
    error = assert_raises(MasterStock::Error) { record('receive', 5) }
    assert_match 'Count Gummies 10 pack at Main store first', error.message

    count = record('count', 12).entry
    assert_nil count.quantity_before
    assert_equal [12, 12], [count.delta, count.quantity_after]
    record('receive', 6, reference: 'PO-77')
    adjust = record('adjust', -2, reason: 'damaged', note: 'Crushed box').entry
    assert_equal [18, 16, -2], [adjust.quantity_before, adjust.quantity_after, adjust.delta]
    recount = record('count', 15).entry
    assert_equal [16, 15, -1], [recount.quantity_before, recount.quantity_after, recount.delta]

    balance = StockBalance.find_by!(stock_item: @item, stock_site: @site)
    assert_equal 15, balance.on_hand
    assert_equal %w[count receive adjust count], StockLedgerEntry.order(:id).pluck(:kind)
    assert_equal [@user.email], StockLedgerEntry.distinct.pluck(:actor)
  end

  test 'adjustments need a reason, a note for Other, and cannot go below zero' do
    record('count', 3)
    assert_raises(MasterStock::Error) { record('adjust', -1) }
    assert_match 'note', assert_raises(MasterStock::Error) { record('adjust', -1, reason: 'other') }.message
    assert_match 'Rupert shows 3 on hand', assert_raises(MasterStock::Error) { record('adjust', -4, reason: 'theft') }.message
    assert_raises(MasterStock::Error) { record('adjust', 0, reason: 'found') }
    assert_raises(MasterStock::Error) { record('count', -1) }
    assert_raises(MasterStock::Error) { record('receive', '2.5') }
    assert_equal 3, StockBalance.find_by!(stock_item: @item).on_hand
    assert_equal 1, StockLedgerEntry.count
  end

  test 'a transfer moves units between sites in one paired step' do
    record('count', 10)
    error = assert_raises(MasterStock::Error) { record('transfer', 4, destination_site: @other_site) }
    assert_match 'Count Gummies 10 pack at Second store', error.message
    record('count', 1, site: @other_site)

    result = record('transfer', 4, destination_site: @other_site, reference: 'Slip 3')
    out, arriving = result.entries
    assert_equal ['transfer_out', -4, 6], [out.kind, out.delta, out.quantity_after]
    assert_equal ['transfer_in', 4, 5], [arriving.kind, arriving.delta, arriving.quantity_after]
    assert_equal out.transfer_group, arriving.transfer_group
    assert_raises(MasterStock::Error) { record('transfer', 7, destination_site: @other_site) }
    assert_raises(MasterStock::Error) { record('transfer', 1, destination_site: @site) }
    assert_equal({ @site.id => 6, @other_site.id => 5 }, StockBalance.pluck(:stock_site_id, :on_hand).to_h)
  end

  test 'a retried submission records once and a reused token with different details is refused' do
    record('count', 5)
    token = SecureRandom.uuid
    first = record('receive', 3, token: token)
    again = record('receive', 3, token: token)
    assert again.replayed
    assert_equal first.entry.id, again.entry.id
    assert_equal 8, StockBalance.find_by!(stock_item: @item).on_hand
    assert_match 'different details', assert_raises(MasterStock::Error) { record('receive', 4, token: token) }.message
  end

  test 'ledger rows cannot be edited or deleted' do
    entry = record('count', 2).entry
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(quantity_after: 9) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.destroy }
  end

  test 'recording needs inventory write in the same workspace and items from that workspace' do
    reader = User.create!(email: "reader-#{SecureRandom.hex(3)}@example.com", password: 'password123', role: 'reader', tenant: @tenant)
    assert_raises(MasterStock::Error) { MasterStock::Ledger.new(actor: reader) }
    other = create_workspace('Other master stock', current: false)
    foreign = Current.set(tenant: other) { StockItem.create!(name: 'Elsewhere', created_by: 'x@example.com') }
    assert_raises(MasterStock::Error) { record('count', 1, item: foreign) }
    assert_equal 0, StockBalance.tenant_unscoped(other.id).count
  end
end
