# frozen_string_literal: true

require 'test_helper'

class TeamChatAlertEvidenceTest < ActiveSupport::TestCase
  test 'bounded alert records preserve filter, counts and incomplete-page warning' do
    rows = 25.times.map do |i|
      { sku: "SKU-#{i}", product: 'A' * 300, quantity: i, threshold: 5, status: 'open', created_at: '2026-10-26T09:00:00-04:00' }
    end
    packed = TeamChat::AlertEvidence.pack({ rows: rows, meta: { has_more: true }, counts: { open: 40 } }, args: { 'query' => 'SKU' })
    text = TeamChat::AlertEvidence.render(["Alert records:\n#{JSON.generate(packed)}"])

    assert_operator JSON.generate(packed).length, :<=, 5_000
    assert_includes text, 'All open alerts: 40'
    assert_includes text, 'status: open; query: SKU'
    assert_includes text, 'SKU-0'
    assert_includes text, 'alert quantity 0, threshold 5'
    assert_includes text, 'Alert IDs or dates were omitted'
    assert_includes text, 'More alert records are available or were omitted'
    assert_includes text, 'may be stale'
  end

  test 'empty filtered alert page never becomes an inventory all-clear' do
    packed = TeamChat::AlertEvidence.pack({ rows: [], meta: { has_more: false, page: 2 }, counts: { open: 3, resolved: 7 } },
      args: { 'status' => 'resolved', 'query' => 'tea' })
    text = TeamChat::AlertEvidence.render(["Alerts:\n#{JSON.generate(packed)}"])
    assert_includes text, 'All resolved alerts: 7'
    assert_includes text, 'status: resolved; query: tea; page: 2'
    assert_includes text, 'No alert records were returned on this page'
    assert_includes text, 'not a current inventory check'
  end

  test 'short alert rows are retained when the whole page fits' do
    rows = 25.times.map { |i| { sku: "SKU-#{i}", quantity: i, threshold: 5, status: 'open', created_at: '2026-10-26T09:00:00-04:00' } }
    packed = TeamChat::AlertEvidence.pack({ rows: rows, meta: { has_more: false } })

    assert_equal 25, packed['rows'].size
    assert_not packed['omitted']
    assert_includes TeamChat::AlertEvidence.render(["Alerts:\n#{JSON.generate(packed)}"]), 'alert created 2026-10-26'
  end

  test 'notes are omitted before alert records when space is limited' do
    rows = 50.times.map { |i| { sku: "SKU-#{i}", quantity: i, threshold: 5, status: 'open', note: 'N' * 100 } }
    packed = TeamChat::AlertEvidence.pack({ rows: rows, meta: { has_more: false } })
    text = TeamChat::AlertEvidence.render(["Alerts:\n#{JSON.generate(packed)}"])

    assert_equal 50, packed['rows'].size
    assert packed['notes_omitted']
    assert_not packed['omitted']
    assert_includes text, 'Alert notes were omitted'
  end

  test 'ids and dates are omitted before alert records when space is limited' do
    rows = 50.times.map { |i| { sku: "SKU-#{i}", id: 'X' * 100, quantity: i, threshold: 5, status: 'open' } }
    packed = TeamChat::AlertEvidence.pack({ rows: rows, meta: { has_more: false } })
    text = TeamChat::AlertEvidence.render(["Alerts:\n#{JSON.generate(packed)}"])

    assert_equal 50, packed['rows'].size
    assert packed['details_omitted']
    assert_not packed['omitted']
    assert_includes text, 'Alert IDs or dates were omitted'
  end

  test 'malformed evidence fails closed' do
    assert_includes TeamChat::AlertEvidence.render(['broken']), 'could not be presented'
  end
end
