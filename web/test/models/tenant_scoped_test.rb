# frozen_string_literal: true

require 'test_helper'

class TenantScopedTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
  end

  teardown { Current.tenant = nil }

  test 'create assigns the current tenant when none is given' do
    Current.tenant = @tenant
    alert = StockAlert.create!(sku: 'X-1', quantity: 1, threshold: 5, status: 'open')
    assert_equal @tenant.id, alert.tenant_id
  end

  test 'create without a current tenant stays unattributed' do
    alert = StockAlert.create!(sku: 'X-1', quantity: 1, threshold: 5, status: 'open')
    assert_nil alert.tenant_id
  end

  test 'create preserves an explicit tenant even under a different current tenant' do
    other = Tenant.create!(name: 'Other Co', subdomain: "other#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    alert = StockAlert.create!(tenant_id: other.id, sku: 'X-1', quantity: 1, threshold: 5, status: 'open')
    assert_equal other.id, alert.tenant_id
  end
end
