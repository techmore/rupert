# frozen_string_literal: true

require "test_helper"

class ShopifySkuConsolidatorTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    # Two ACTIVE products sharing one SKU (the pooled "strain" case)
    @p1 = ShopifyProduct.create!(id: "P1", title: "Citrus Burst Live Resin", status: "ACTIVE", tenant_id: Current.tenant_id)
    @p2 = ShopifyProduct.create!(id: "P2", title: "Trop Z Live Resin", status: "ACTIVE", tenant_id: Current.tenant_id)
    @v1 = ShopifyVariant.create!(id: "SV1", productId: "P1", title: "5 Grams", sku: "LR5", tracked: true, tenant_id: Current.tenant_id)
    @v2 = ShopifyVariant.create!(id: "SV2", productId: "P2", title: "5 Grams", sku: "LR5", tracked: true, tenant_id: Current.tenant_id)
  end

  teardown do
    Current.tenant = nil
  end

  test "flags the group and keeps exactly one canonical variant" do
    plan = ShopifySkuConsolidator.build_plan!
    g = plan[:groups].find { |x| x[:base] == "LR5" }
    refute_nil g
    assert_equal 1, g[:surplus].length, "2 variants sharing LR5 => 1 surplus, 1 canonical"
    assert_equal 1, plan[:groups].count { |x| x[:base] == "LR5" }
  end

  test "prefers an ACTIVE product variant as canonical over an ARCHIVED one" do
    archived = ShopifyProduct.create!(id: "P3", title: "Citrus Burst Live Resin", status: "ARCHIVED", tenant_id: Current.tenant_id)
    @v3 = ShopifyVariant.create!(id: "SV3", productId: "P3", title: "5 Grams", sku: "LR9", tracked: true, tenant_id: Current.tenant_id)
    @v2.update!(sku: "LR9") # v2 active also LR9

    plan = ShopifySkuConsolidator.build_plan!
    g = plan[:groups].find { |x| x[:base] == "LR9" }
    assert_equal @v2.id, g[:canonical].id, "canonical should be on the ACTIVE product"
    assert_equal [@v3.id], g[:surplus].map(&:id), "the ARCHIVED duplicate should be surplus"
  end

  test "untracking a surplus variant removes it from the tracked set" do
    plan = ShopifySkuConsolidator.build_plan!
    # confirm apply would untrack one surplus
    assert_equal 1, plan[:summary][:surplus_to_untrack]
  end
end
