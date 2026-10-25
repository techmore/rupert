# frozen_string_literal: true

require 'test_helper'

class ItemCostTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  test 'parses plain amounts into cents and refuses anything else' do
    assert_equal 650, ItemCost.parse_cents('6.5')
    assert_equal 123_450, ItemCost.parse_cents('$1,234.50')
    assert_equal 0, ItemCost.parse_cents('0')
    assert_equal 50, ItemCost.parse_cents('.50')
    assert_nil ItemCost.parse_cents('')
    assert_nil ItemCost.parse_cents('-1')
    assert_nil ItemCost.parse_cents('1.234')
    assert_nil ItemCost.parse_cents('six')
  end

  test 'one cost per variant per tenant, scoped to the current tenant' do
    ItemCost.create!(shopify_variant_id: 'v1', cost_cents: 100)
    assert_not ItemCost.new(shopify_variant_id: 'v1', cost_cents: 200).valid?
    assert_not ItemCost.new(shopify_variant_id: 'v2', cost_cents: -1).valid?
    Current.tenant = nil
    assert_empty ItemCost.all
  end
end
