# frozen_string_literal: true

require 'test_helper'

class SquareSkuAuditTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Current.tenant = nil
  end

  def stub_square_api
    SquareClient.stubs(:locations).returns([{ 'id' => 'L1', 'name' => 'Home', 'type' => 'PHYSICAL' }])
    SquareClient.stubs(:catalog).returns([
                                           { variationId: 'V1', itemId: 'I1', sku: 'HERB-1', name: 'Herb 1' },
                                           { variationId: 'V2', itemId: 'I1', sku: '',          name: 'Herb 1 no-sku' },
                                           { variationId: 'V3', itemId: 'I2', sku: 'DUP',       name: 'Dup a' },
                                           { variationId: 'V4', itemId: 'I3', sku: 'DUP',       name: 'Dup b' },
                                           { variationId: 'V5', itemId: 'I4', sku: 'SOLD',      name: 'Sellable' }
                                         ])
    SquareClient.stubs(:inventory_counts).returns({ counts: { 'V1' => 5, 'V5' => 3 } })
  end

  test 'flags variations without a SKU' do
    stub_square_api
    result = SquareSkuAudit.run!
    assert_equal 1, result.summary[:without_sku] # only V2 (V1,V3,V4,V5 have SKUs)
    assert(result.missing_sku.any? { |v| v[:variationId] == 'V2' })
  end

  test 'classifies sellable-but-unlinked variations' do
    stub_square_api
    ShopifyProduct.create!(id: 'P1', title: 'Herb', tenant_id: Current.tenant_id)
    variant = ShopifyVariant.create!(id: 'SV1', productId: 'P1', title: 'Herb 1', sku: 'HERB-1', tracked: true,
                                     tenant_id: Current.tenant_id)
    SquareItem.create!(id: 'I1', name: 'Herb', tenant_id: Current.tenant_id)
    SquareVariation.create!(id: 'V1', itemId: 'I1', name: 'Herb 1', sku: 'HERB-1', tenant_id: Current.tenant_id)
    SkuLink.create!(sku: 'HERB-1', shopifyVariantId: variant.id, squareVariationId: 'V1', auto: true,
                    tenant_id: Current.tenant_id)
    result = SquareSkuAudit.run!
    # V5 (SOLD, qty 3) is sellable and unlinked; V1 is linked, V2 has no sku (not sellable, qty 0).
    assert_equal 1, result.summary[:sellable_unlinked]
    assert result.sellable_unlinked.map { |v| v[:variationId] }.include?('V5')
  end

  test 'flags stale mirror rows no longer in the live catalog' do
    stub_square_api
    SquareVariation.create!(id: 'OLD', itemId: 'I1', name: 'Gone', sku: 'OLD', tenant_id: Current.tenant_id)
    result = SquareSkuAudit.run!
    assert_equal 1, result.summary[:stale_mirror]
    assert_equal ['OLD'], result.stale_mirror.map(&:id)
  end

  test 'flags duplicate SKUs used across variations' do
    stub_square_api
    result = SquareSkuAudit.run!
    assert_equal 1, result.summary[:duplicate_skus]
    assert result.duplicate_skus.key?('dup')
  end
end
