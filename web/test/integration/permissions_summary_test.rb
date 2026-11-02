# frozen_string_literal: true

require 'test_helper'

# Permissions → Summary: a read-only grid of what each role allows, built from
# the same methods the app uses to authorize.
class PermissionsSummaryTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.tenant = @tenant
    EnvStore.set('SHOPIFY_CLIENT_ID', 'test-client-id')
    EnvStore.set('SHOPIFY_CLIENT_SECRET', 'test-client-secret')
  end

  teardown { Current.reset }

  def sign_in(user, password = 'password')
    post login_path, params: { email: user.email, password: password }
  end

  def cell(role, row)
    css_select("tr[data-row='#{row}'] td[data-role='#{role}']").first
  end

  test 'an administrator sees every role and the grouped grid' do
    sign_in(@admin)
    get roles_permissions_path
    assert_response :success

    assert_select 'h1', 'Permissions'
    assert_select 'nav.tabs a[aria-current=page]', 'Summary'
    User.roles.each_key { |role| assert_select "thead th[data-role='#{role}']", 1 }
    %w[Key\ abilities Sell Stock Bookkeeping Team\ and\ time Payroll System].each do |area|
      assert_select "tbody[data-area='#{area}']", 1
    end
    # Allowed and not allowed are words, not colour alone.
    assert_equal 'Yes', cell('admin', 'payroll.read').text.strip
    assert_equal 'No', cell('cashier', 'payroll.read').text.strip
    assert_select 'td[data-allowed]' do |cells|
      cells.each { |td| assert_includes %w[Yes No], td.text.strip }
    end
  end

  test 'derived abilities follow the authorization methods' do
    sign_in(@admin)
    get roles_permissions_path

    { 'manage_accounts' => %w[super_admin admin],
      'review_timesheets' => %w[super_admin admin manager shift_leader],
      'approve_clock_corrections' => %w[super_admin admin],
      'see_payroll' => %w[super_admin admin],
      'review_receipts' => %w[super_admin admin manager] }.each do |ability, allowed_roles|
      User.roles.each_key do |role|
        expected = allowed_roles.include?(role) ? 'true' : 'false'
        assert_equal expected, cell(role, ability)['data-allowed'], "#{ability} for #{role}"
      end
    end
    assert_equal 'true', cell('employee', 'use_pos')['data-allowed']
    assert_equal 'false', cell('employee', 'sales.read')['data-allowed']
  end

  test 'a business role change shows in the grid and marks the role' do
    RolePermission.create!(tenant_id: @tenant.id, role: 'cashier', permission: 'payroll.read', enabled: true)
    sign_in(@admin)
    get roles_permissions_path

    assert_equal 'true', cell('cashier', 'payroll.read')['data-allowed']
    assert_equal 'false', cell('cashier', 'sales.read')['data-allowed']
    assert_select "thead th[data-role='cashier'] [data-role-changed]", 1
    assert_select "thead th[data-role='reader'] [data-role-changed]", 0
  end

  test 'the staff role stays fixed even when a role change tries to widen it' do
    RolePermission.create!(tenant_id: @tenant.id, role: 'employee', permission: 'payroll.read', enabled: true)
    sign_in(@admin)
    get roles_permissions_path

    assert_equal 'false', cell('employee', 'payroll.read')['data-allowed']
    assert_select "thead th[data-role='employee'] [data-role-changed]", 0
  end

  test 'people with personal permission lists are counted' do
    other = User.create!(email: 'override@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id)
    other.update_permission_overrides!(%w[dashboard.read])
    sign_in(@admin)
    get roles_permissions_path

    assert_select '[data-personal-overrides]', /1 user in this business has a personal permission list/
  end

  test 'roles without account management cannot open the summary or see its tab' do
    manager = User.create!(email: 'manager-perms@example.com', password: 'password123', role: 'manager', tenant_id: @tenant.id)
    sign_in(manager, 'password123')
    get roles_permissions_path
    assert_redirected_to root_path

    # A manager given users.read can open the editor read-only, still without the summary.
    manager.update_permission_overrides!(User::ROLE_PERMISSIONS.fetch('manager') + ['users.read'])
    get permissions_path
    assert_response :success
    assert_select 'nav.tabs', 0
    get roles_permissions_path
    assert_redirected_to root_path
  end

  test 'the editor shows both tabs to an administrator' do
    sign_in(@admin)
    get permissions_path
    assert_select 'nav.tabs a', 2
    assert_select 'nav.tabs a[aria-current=page]', 'Edit roles'
  end

  test 'every permission in the role maps and the catalog appears in the grid' do
    sign_in(@admin)
    get roles_permissions_path
    rows = css_select('tr[data-row]').map { |tr| tr['data-row'] }

    from_roles = User::ROLE_PERMISSIONS.values.flatten.uniq - ['*']
    (from_roles + User.all_permissions).uniq.each do |permission|
      assert_includes rows, permission, "#{permission} is missing from the Permissions summary"
    end
    RoleAccessGrid::ABILITIES.each { |key, *| assert_includes rows, key }
  end

  test 'every built-in permission has a plain-language sentence and area' do
    from_roles = User::ROLE_PERMISSIONS.values.flatten.uniq - ['*']
    builtin = User.builtin_permission_catalog.flat_map { |group| group[:permissions] }
    (from_roles + builtin).uniq.each do |permission|
      assert RoleAccessGrid::PERMISSIONS.key?(permission), "Add a sentence for #{permission} to RoleAccessGrid::PERMISSIONS"
      area = RoleAccessGrid::PERMISSIONS.fetch(permission).first
      assert_includes RoleAccessGrid::AREA_ORDER, area
    end
    stale = RoleAccessGrid::PERMISSIONS.keys - User.all_permissions
    assert_empty stale, "RoleAccessGrid::PERMISSIONS describes permissions that no longer exist: #{stale.join(', ')}"
  end

  test 'grid cells match User#can? for a role with no changes' do
    grid = RoleAccessGrid.new(tenant_id: @tenant.id)
    User.roles.each_key do |role|
      user = User.create!(email: "grid-#{role}@example.com", password: 'password123', role: role, tenant_id: @tenant.id)
      User.all_permissions.each do |permission|
        next if permission == 'timesheets.self' # also granted by a linked staff record, per person

        assert_equal user.can?(permission), grid.allowed?(role, permission), "#{role} #{permission}"
      end
      assert_equal user.can_review_timesheets?, grid.allowed?(role, 'review_timesheets')
      assert_equal user.can_manage_accounts?, grid.allowed?(role, 'manage_accounts')
    end
  end
end
