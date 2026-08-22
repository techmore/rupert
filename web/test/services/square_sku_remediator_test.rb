# frozen_string_literal: true

require 'test_helper'

class SquareSkuRemediatorTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @product = ShopifyProduct.create!(id: 'P1', title: 'King Cone Pre-Roll - THCA', tenant_id: Current.tenant_id)
    @short = ShopifyVariant.create!(id: 'SV1', productId: 'P1', title: 'Pineapple Trainwreck (Sativa)', sku: 'PT',
                                    tracked: true, tenant_id: Current.tenant_id)
    @flower = ShopifyVariant.create!(id: 'SV2', productId: 'P1', title: '3.5 Grams', sku: 'KUSH',
                                     tracked: true, tenant_id: Current.tenant_id)
    SquareItem.create!(id: 'I1', name: 'King Cone', tenant_id: Current.tenant_id)
  end

  teardown do
    Current.tenant = nil
  end

  def stub(catalog, counts)
    SquareClient.stubs(:locations).returns([{ 'id' => 'L1', 'name' => 'Home', 'type' => 'PHYSICAL' }])
    SquareClient.stubs(:catalog).returns(catalog)
    SquareClient.stubs(:inventory_counts).returns({ counts: counts })
  end

  test 'only auto-links variations with a confident NAMED match; skips generic sizes' do
    stub(
      [
        { variationId: 'V1', itemId: 'I1', sku: 'Q188573', name: 'Pineapple Trainwreck (Sativa)' }, # named + strong -> link
        { variationId: 'V2', itemId: 'I1', sku: 'G', name: '3.5 Grams' } # generic size -> skip
      ],
      { 'V1' => 5, 'V2' => 3 }
    )

    plan = SquareSkuRemediator.build_plan!
    square_ids = plan[:links_to_create].map { |r| r[:square][:variationId] }
    assert_includes square_ids, 'V1'
    refute_includes square_ids, 'V2'
    assert_equal 1, plan[:summary][:links]
  end
end
