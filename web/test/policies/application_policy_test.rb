# frozen_string_literal: true

require "test_helper"

# Super admins are platform-wide (effective_permissions ["*"]) and must bypass
# the per-record tenant isolation guard, just as they bypass module permission
# checks. Without this, a superadmin reviewing a record of another tenant is
# wrongly denied (the intermittent "You don't have permission to do that.").
class ApplicationPolicyTest < ActiveSupport::TestCase
  setup do
    @home = tenants(:default_tenant)
    @other = Tenant.create!(name: "Other Store", subdomain: "other", shopify_shop_domain: "other.myshopify.com", status: "active")

    @super_admin = User.create!(email: "platform@example.com", password: "password123", role: "super_admin", tenant_id: @home.id, name: "Platform")
    @manager = User.create!(email: "manager@example.com", password: "password123", role: "manager", tenant_id: @home.id, name: "Mgr")
  end

  test "a super admin bypasses the tenant guard on record policies" do
    record = OpenStruct.new(tenant_id: @other.id)
    policy = Sales::PosSessionPolicy.new(@super_admin, record)
    assert policy.show?, "super admin should be able to view records of any tenant"
  end

  test "a non-super-admin is still denied a record from another tenant" do
    record = OpenStruct.new(tenant_id: @other.id)
    policy = Sales::PosSessionPolicy.new(@manager, record)
    refute policy.show?, "manager must not view another tenant's records"
  end

  test "a non-super-admin can view a record of their own tenant" do
    record = OpenStruct.new(tenant_id: @home.id)
    policy = Sales::PosSessionPolicy.new(@manager, record)
    assert policy.show?, "manager should view records of their own tenant"
  end
end