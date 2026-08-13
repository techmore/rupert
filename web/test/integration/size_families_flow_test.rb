# frozen_string_literal: true

require "test_helper"

class SizeFamiliesFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "SF Co", subdomain: "sfco#{SecureRandom.hex(4)}")
    @admin = User.create!(email: "sf-admin@example.com", password: "password123", role: "admin", name: "Admin", tenant_id: @tenant.id)
    post login_path, params: { email: @admin.email, password: "password123" }
    Current.tenant = @tenant
    open_push_window!("square")
  end

  teardown do
    Current.tenant = nil
  end

  test "creating a family, adding sizes, deriving, and approving works end to end" do
    post size_families_path, params: { size_family: { name: "Afghan Hash", root_sku: "afghan1", mode: "approval" } }
    assert_redirected_to(size_families_path)
    family = SizeFamily.find_by!(name: "Afghan Hash")

    post add_member_size_family_path(family), params: { sku: "afghan35", grams: "3.5" }
    assert_redirected_to(edit_size_family_path(family))
    post add_member_size_family_path(family), params: { sku: "afghan7", grams: "7" }
    assert_redirected_to(edit_size_family_path(family))
    family.reload
    assert_equal 2, family.members.count

    SquareClient.stubs(:configured?).returns(false)
    SquareVariation.create!(id: "v35", itemId: "item1", sku: "afghan35", name: "3.5 Grams", tenant_id: @tenant.id)
    SquareVariation.create!(id: "v7", itemId: "item1", sku: "afghan7", name: "7 Grams", tenant_id: @tenant.id)
    family.update!(base_grams: 105)
    post derive_size_family_path(family)
    assert_redirected_to(size_families_path)
    assert_equal 2, family.size_changes.pending.count
    assert_equal({ "afghan35" => 30, "afghan7" => 15 }, family.size_changes.pending.to_h { |c| [c.sku, c.target_quantity] })

    home = Location.create!(source: "square", externalId: "HOME", name: "Home")
    SquareSyncer.stubs(:primary_location_id).returns(home)
    SquareClient.stubs(:request).returns({})
    first = family.size_changes.pending.first
    post approve_size_family_path(family, change_id: first.id)
    assert_redirected_to(size_families_path)
    assert_equal "applied", first.reload.status

    post approve_all_size_family_path(family)
    assert_redirected_to(size_families_path)
    assert_equal 0, family.size_changes.pending.count
    assert_equal 2, family.size_changes.where(status: "applied").count
  end

  test "collection approve_all applies pending sizes across families (no 404)" do
    first = SizeFamily.create!(name: "First", mode: "approval", tenant_id: @tenant.id)
    second = SizeFamily.create!(name: "Second", mode: "approval", tenant_id: @tenant.id)
    [first, second].each do |family|
      SquareVariation.create!(id: "v-#{family.id}", itemId: "item-#{family.id}",
        sku: "sku-#{family.id}", name: family.name, tenant_id: @tenant.id)
      SizeChange.create!(family_id: family.id, sku: "sku-#{family.id}", grams: 3.5,
        root_grams: 10, target_quantity: 2, square_variation_id: "v-#{family.id}",
        tenant_id: @tenant.id, status: "pending")
    end
    home = Location.create!(source: "square", externalId: "HOME", name: "Home")
    SquareSyncer.stubs(:primary_location_id).returns(home)
    SquareClient.stubs(:request).returns({})

    post approve_all_size_families_path

    assert_redirected_to(size_families_path)
    assert_equal 0, SizeChange.pending.count
    assert_equal 2, SizeChange.where(status: "applied").count
  end

  test "manual root override resets the sales watermark" do
    family = SizeFamily.create!(name: "Override", mode: "approval", tenant_id: @tenant.id)
    family.update!(sales_watermark: 2.days.ago)
    post set_root_size_family_path(family), params: { base_grams: "420" }
    assert_redirected_to(size_families_path)
    family.reload
    assert_equal 420.0, family.base_grams.to_f
    assert_operator family.sales_watermark, :>, 1.minute.ago
  end

  test "index shows families and pending changes" do
    family = SizeFamily.create!(name: "Reader Co", mode: "approval", tenant_id: @tenant.id)
    SizeChange.create!(family_id: family.id, sku: "x3", grams: 3.5, root_grams: 10, target_quantity: 2,
      square_variation_id: "v3", tenant_id: @tenant.id, status: "pending")

    get size_families_path
    assert_response :success
    assert_includes response.body, "Reader Co"
    assert_includes response.body, "Pending approvals"
  end

  test "a reader cannot create or approve" do
    reader = User.create!(email: "sf-reader2@example.com", password: "password123", role: "reader", name: "Reader", tenant_id: @tenant.id)
    post login_path, params: { email: reader.email, password: "password123" }

    post size_families_path, params: { size_family: { name: "Nope" } }
    assert_redirected_to(root_path)
    assert_nil SizeFamily.find_by(name: "Nope")
  end
end
