# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

# Settings → Time rules: workspace defaults and per-store overrides, saved by settings writers.
class TimeRulesSettingsTest < ActionDispatch::IntegrationTest
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  test 'saves workspace defaults and a store override, showing the override badge' do
    store = Location.create!(name: 'Second store', source: 'rupert', externalId: 'second', active: true)
    tp_sign_in(@admin)
    get time_rules_settings_path
    assert_response :success
    assert_select 'h1', 'Time rules'
    assert_select 'select[name="time_rules[preset]"]'
    post time_rules_settings_path, params: { time_rules: { preset: 'massachusetts', meal_break_minutes: '30', rounding_minutes: '0', pin_length: '4', tip_method: 'pool',
                                                           minor_age: '18', schedule_notice_days: '10', break_reminders: '1' } }
    assert_redirected_to time_rules_settings_path(location_id: nil)
    Current.tenant = @tenant
    assert_equal 'massachusetts', TimeRules.for.preset
    assert_equal 10, TimeRules.for.schedule_notice_days
    assert TimeRules.for.sick_accrues?, 'the Massachusetts preset turns sick accrual on'
    assert_not TimeRules.for.meal_break_paid?, 'an unticked box saves as false'
    post time_rules_settings_path(location_id: store.id), params: { time_rules: { preset: 'massachusetts', meal_break_minutes: '45', rounding_minutes: '0', pin_length: '4', tip_method: 'pool',
                                                                                  minor_age: '18', schedule_notice_days: '10', break_reminders: '1' } }
    assert_redirected_to time_rules_settings_path(location_id: store.id)
    assert_nil flash[:alert]
    Current.reset # the per-request rules cache lives in Current; a request resets it, the test thread must too
    Current.tenant = @tenant
    assert_equal 45, TimeRules.for(store).meal_break_minutes
    assert_equal 30, TimeRules.for.meal_break_minutes
    get time_rules_settings_path(location_id: store.id)
    assert_select 'label[for="tr_meal_minutes"] .rules-override', text: 'Store override'
    assert_select 'label[for="tr_meal_after"] .rules-override', count: 0
    post time_rules_settings_path, params: { time_rules: { rounding_minutes: '7' } }
    assert_match(/Rounding must be/, flash[:alert])
  end

  test 'managers can read but not save, and it is in the System rail for settings writers' do
    tp_sign_in(@manager)
    get time_rules_settings_path
    assert_response :redirect
    tp_sign_in(@admin)
    get settings_path
    assert_select 'nav[aria-label="Module"] a[href=?]', time_rules_settings_path, text: 'Time rules'
  end
end
