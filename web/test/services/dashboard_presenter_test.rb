# frozen_string_literal: true

require 'test_helper'

class DashboardPresenterTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    @product = ShopifyProduct.create!(id: 'p1', title: 'Widget', tenant_id: @tenant.id)
    @sv = ShopifyVariant.create!(id: 'sv1', title: 'Small', sku: 'WIDGET', productId: @product.id,
                                 tenant_id: @tenant.id)
    @sqv = SquareItem.create!(id: 'si1', name: 'Widget', tenant_id: @tenant.id)
    @sq_variation = SquareVariation.create!(id: 'sqv1', sku: 'WIDGET', name: 'Small', itemId: @sqv.id,
                                            tenant_id: @tenant.id)
    @shop_location = Location.create!(source: 'shopify', externalId: 'SHOP', name: 'Shop', tenant_id: @tenant.id)
    @sq_location = Location.create!(source: 'square', externalId: 'SQ', name: 'Home', tenant_id: @tenant.id)
  end

  teardown { Current.tenant = nil }

  def add_link!
    SkuLink.create!(sku: 'WIDGET', shopifyVariantId: @sv.id, squareVariationId: @sq_variation.id, tenant_id: @tenant.id)
  end

  def set_shopify_qty(qty)
    level = InventoryLevel.find_or_initialize_by(source: 'shopify', locationId: @shop_location.id,
                                                 shopifyVariantId: @sv.id)
    level.update!(quantity: qty, available: qty)
  end

  def set_square_qty(qty)
    level = InventoryLevel.find_or_initialize_by(source: 'square', locationId: @sq_location.id,
                                                 squareVariationId: @sq_variation.id)
    level.update!(quantity: qty, available: qty)
  end

  test 'sku_mismatches counts linked skus whose SKUs differ from Square' do
    add_link!
    assert_equal 0, DashboardPresenter.new.sku_mismatches

    @sq_variation.update!(sku: 'DIFFERENT')
    DataCache.bump!
    assert_equal 1, DashboardPresenter.new.sku_mismatches
  end

  test 'sku_mismatches ignores quantity differences and unlinked items' do
    other_variation = SquareVariation.create!(id: 'sqv2', sku: 'UNLINKED', name: 'B', itemId: @sqv.id,
                                              tenant_id: @tenant.id)
    add_link!
    set_shopify_qty(5)
    set_square_qty(7) # quantities differ across locations — normal, not a mismatch
    InventoryLevel.create!(source: 'square', locationId: @sq_location.id, squareVariationId: other_variation.id,
                           quantity: 9, available: 9, tenant_id: @tenant.id)

    assert_equal 0, DashboardPresenter.new.sku_mismatches
  end
end
