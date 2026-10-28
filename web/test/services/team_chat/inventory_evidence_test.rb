# frozen_string_literal: true

require 'test_helper'

class TeamChatInventoryEvidenceTest < ActiveSupport::TestCase
  test 'preserves unknown amounts and pagination without merging separate observations' do
    data = { rows: [
      { name: 'Tea', location: 'Shelf', source: 'shopify', available: nil, low: nil },
      { name: 'Tea', location: 'Shelf', source: 'square', available: 2, low: true }
    ], meta: { has_more: true } }
    text = TeamChat::InventoryEvidence.render(["result\n#{JSON.generate(data)}"])
    assert_includes text, 'Shelf (shopify): unknown available; low-stock status unknown'
    assert_includes text, 'Shelf (square): 2 available; low stock'
    assert_includes text, 'paginated'
  end

  test 'reports a truncated result as unavailable instead of inventing stock' do
    text = TeamChat::InventoryEvidence.render(["result\n{\"rows\":["])
    assert_includes text, 'could not be presented'
  end

  test 'distinguishes no rows from zero stock and removes contact information from labels' do
    empty = TeamChat::InventoryEvidence.render(["result\n#{JSON.generate(rows: [], meta: { has_more: false })}"])
    assert_includes empty, 'No stock rows matched'
    assert_not_includes empty, '0 available'

    data = { rows: [{ name: 'person@example.com', location: 'Shelf', source: 'shopify', available: 0, low: false }], meta: {} }
    text = TeamChat::InventoryEvidence.render(["result\n#{JSON.generate(data)}"])
    assert_not_includes text, 'person@example.com'
    assert_includes text, '0 available; not marked low stock'
  end
end
