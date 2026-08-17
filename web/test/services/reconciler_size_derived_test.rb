# frozen_string_literal: true

require "test_helper"

class ReconcilerSizeDerivedTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @tenant = tenants(:default_tenant)
    @sku = "thash35"
    SquareVariation.create!(id: "sv1", itemId: "i1", sku: @sku, name: "3.5 Grams", tenant_id: @tenant.id)
    # Reconcile only considers variants of ACTIVE (sellable) products.
    ShopifyProduct.create!(id: "p1", title: "THCA Hash", status: "ACTIVE", tenant_id: @tenant.id)
    variant = ShopifyVariant.create!(sku: @sku, title: "3.5 Grams", tracked: true, inventoryQuantity: 10,
      inventoryItemId: "ii1", productId: "p1", tenant_id: @tenant.id)
    SkuLink.create!(shopifyVariantId: variant.id, squareVariationId: "sv1", sku: @sku, auto: true, tenant_id: @tenant.id)
  end

  teardown do
    Current.tenant = nil
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
end
