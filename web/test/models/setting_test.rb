# frozen_string_literal: true

require 'test_helper'

class SettingTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @other = Tenant.create!(name: 'Other shop', subdomain: 'setting-other', status: 'active')
    Setting.create!(key: 'k', value: 'mine', tenant_id: @tenant.id)
    Setting.create!(key: 'k', value: 'theirs', tenant_id: @other.id)
    Setting.create!(key: 'k', value: 'platform', tenant_id: nil)
  end

  teardown { Current.reset }

  test 'for_tenant, of_tenant and global never mix workspaces or platform rows' do
    Current.set(tenant: @tenant) do
      assert_equal 'mine', Setting.for_tenant('k').value
      assert_equal %w[mine], Setting.of_tenant.where(key: 'k').map(&:value)
    end
    Current.set(tenant: @other) { assert_equal 'theirs', Setting.for_tenant('k').value }
    assert_equal 'mine', Setting.for_tenant('k', @tenant.id).value
    assert_equal 'platform', Setting.global('k').value
    assert_equal %w[platform], Setting.platform.where(key: 'k').map(&:value)
  end
end
