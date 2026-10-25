# frozen_string_literal: true

require 'test_helper'

# Settings → Pay rules (#423): owners with the settings permission choose the pay period and
# overtime; everyone else can at most read them.
class PayRulesSettingsTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
  end

  teardown { Current.reset }

  test 'an owner sees the pay period is not chosen, chooses every two weeks and it is logged' do
    post login_path, params: { email: @owner.email, password: 'password' }
    get settings_path
    assert_response :success
    assert_select '#pay-rules [data-pay-period-unchosen]', text: 'Not chosen'
    assert_select '#pay-rules', /Until it is, Rupert uses Weekly, Thursday to Wednesday/
    assert_select '#pay-rules input[name="overtime_enabled"]:not([checked])'
    post pay_rules_settings_path, params: { pay_period: 'biweekly', week_start_day: 'thursday', anchor_date: '2026-10-01',
                                            overtime_threshold_hours: '40', overtime_multiplier: '1.5' }
    assert_redirected_to settings_path(anchor: 'pay-rules')
    Current.reset
    Current.tenant = tenants(:default_tenant)
    rules = PayRules.current
    assert rules.biweekly?
    assert rules.chosen?
    assert_not rules.overtime_enabled?
    log = ActivityLog.where(action: 'pay_rules_saved').last
    assert_includes log.details, 'Every two weeks, Thursday to Wednesday from 2026-10-01'
    assert_includes log.details, 'overtime off'
    follow_redirect!
    assert_select '#pay-rules [data-pay-period-chosen]', text: 'Chosen'
  end

  test 'a bad choice is refused with a message' do
    post login_path, params: { email: @owner.email, password: 'password' }
    post pay_rules_settings_path, params: { pay_period: 'biweekly', week_start_day: 'thursday', anchor_date: '' }
    assert_redirected_to settings_path(anchor: 'pay-rules')
    assert_match(/needs the first day/, flash[:alert])
    assert_not PayRules.load(Current.tenant.id).chosen?
  end

  test 'staff without the settings permission cannot change the pay rules' do
    user = User.create!(tenant: Current.tenant, email: 'pay-rules-manager@example.com', role: 'manager', password: 'password123')
    post login_path, params: { email: user.email, password: 'password123' }
    post pay_rules_settings_path, params: { pay_period: 'weekly', week_start_day: 'monday' }
    assert_not PayRules.load(Current.tenant.id).chosen?
  end
end
