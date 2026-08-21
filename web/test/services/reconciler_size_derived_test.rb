# frozen_string_literal: true

require "test_helper"

class ReconcilerSizeDerivedTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    @sku = "thash35"
    # Reconciler memoizes shared/multiloc SKU sets at class level; reset them so
    # each test computes fresh regardless of what earlier (or foreign) tests ran.
    Reconciler.instance_variable_set(:@shared_skus, nil)
    Reconciler.instance_variable_set(:@multiloc_skus, nil)
    SquareVariation.create!(id: "sv1", itemId: "i1", sku: @sku, name: "3.5 Grams", tenant_id: @tenant.id)
    # Reconcile only considers variants of ACTIVE (sellable) products.
    ShopifyProduct.create!(id: "p1", title: "THCA Hash", status: "ACTIVE", tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(sku: @sku, title: "3.5 Grams", tracked: true, inventoryQuantity: 10,
      inventoryItemId: "ii1", productId: "p1", tenant_id: @tenant.id)
    SkuLink.create!(shopifyVariantId: variant.id, squareVariationId: "sv1", sku: @sku, auto: true, tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
    Reconciler.instance_variable_set(:@shared_skus, nil)
    Reconciler.instance_variable_set(:@multiloc_skus, nil)
  end

  test "size-family SKUs are marked derived and excluded from actionable rows" do
    family = SizeFamily.create!(name: "Hash", mode: "approval", tenant_id: @tenant.id)
    family.members.create!(sku: @sku, grams: 3.5, tenant_id: @tenant.id)

    rows = Reconciler.build_rows
    row = rows.find { |r| r.sku == @sku }
    assert row.derived
    refute_includes Reconciler.actionable_rows(rows).map(&:sku), @sku
  end

  test "SKUs outside any size family remain actionable" do
    rows = Reconciler.build_rows
    row = rows.find { |r| r.sku == @sku }
    refute row.derived
    assert_includes Reconciler.actionable_rows(rows).map(&:sku), @sku
  end

  test "multi-location Square SKUs are excluded from actionable rows" do
    # Stock spread over two Square locations can't be reconciled to a single
    # home PHYSICAL_COUNT, so the Reconciler must skip it (not propose it and
    # later trip the negative-home-base preflight).
    home = Location.create!(id: "locA", name: "Home", source: "square", externalId: "locA", tenant_id: @tenant.id)
    mobile = Location.create!(id: "locB", name: "Mobile", source: "square", externalId: "locB", tenant_id: @tenant.id)
    InventoryLevel.create!(id: "lvl1", source: "square", squareVariationId: "sv1", locationId: home.id, quantity: 16, tenant_id: @tenant.id)
    InventoryLevel.create!(id: "lvl2", source: "square", squareVariationId: "sv1", locationId: mobile.id, quantity: 6, tenant_id: @tenant.id)

    assert_includes Reconciler.multiloc_skus, @sku
    rows = Reconciler.build_rows
    refute_includes Reconciler.actionable_rows(rows).map(&:sku), @sku
  end

  test "single-location Square SKUs stay reconcilable" do
    home = Location.create!(id: "locC", name: "Home", source: "square", externalId: "locC", tenant_id: @tenant.id)
    # One location, and a square qty that differs from the Shopify qty (10) so
    # the row carries a real delta and would be actionable.
    InventoryLevel.create!(id: "lvl3", source: "square", squareVariationId: "sv1", locationId: home.id, quantity: 15, tenant_id: @tenant.id)

    assert_not_includes Reconciler.multiloc_skus, @sku
    rows = Reconciler.build_rows
    assert_includes Reconciler.actionable_rows(rows).map(&:sku), @sku
  end
end
