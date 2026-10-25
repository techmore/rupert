# frozen_string_literal: true

require 'test_helper'

# The workspace pay rules (#423): pay period, start day and overtime.
class PayRulesTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
  end

  teardown { Current.reset }

  test 'until someone chooses, the period is weekly from Thursday, not chosen, and overtime is off' do
    rules = PayRules.current
    assert_not rules.chosen?
    assert_not PayRules.pay_period_chosen?
    assert_equal 'Weekly, Thursday to Wednesday', rules.summary
    assert_equal [Date.new(2026, 10, 15), Date.new(2026, 10, 21)], rules.period_range(Date.new(2026, 10, 20))
    assert_not rules.overtime_enabled?
    assert_equal 40, rules.overtime_threshold_hours
    assert_equal BigDecimal('1.5'), rules.overtime_multiplier
  end

  test 'saving the pay period marks it chosen by whoever saved it' do
    PayRules.save!({ pay_period: 'weekly', week_start_day: 'sunday' }, actor: @owner)
    rules = PayRules.current
    assert rules.chosen?
    assert_equal @owner.display_name.presence || @owner.email, rules.chosen_by
    assert_equal 'Weekly, Sunday to Saturday', rules.summary
    assert_equal Date.new(2026, 10, 18), rules.period_start(Date.new(2026, 10, 20))
  end

  test 'every two weeks counts 14-day periods from the anchor, before and after it' do
    rules = PayRules.save!({ pay_period: 'biweekly', week_start_day: 'thursday', anchor_date: '2026-10-01' }, actor: @owner)
    assert_equal [Date.new(2026, 10, 15), Date.new(2026, 10, 28)], rules.period_range(Date.new(2026, 10, 20))
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 14)], rules.period_range(Date.new(2026, 10, 14))
    assert_equal [Date.new(2026, 9, 17), Date.new(2026, 9, 30)], rules.period_range(Date.new(2026, 9, 24))
    assert_equal Date.new(2026, 10, 15), rules.week_start(Date.new(2026, 10, 20))
  end

  test 'invalid choices are refused and nothing is saved' do
    assert_raises(PayRules::Invalid) { PayRules.save!({ pay_period: 'monthly' }, actor: @owner) }
    assert_raises(PayRules::Invalid) { PayRules.save!({ pay_period: 'biweekly', week_start_day: 'thursday' }, actor: @owner) }
    assert_raises(PayRules::Invalid) do
      PayRules.save!({ pay_period: 'biweekly', week_start_day: 'thursday', anchor_date: '2026-10-02' }, actor: @owner)
    end
    assert_raises(PayRules::Invalid) { PayRules.save!({ overtime_multiplier: '0.5' }, actor: @owner) }
    assert_not PayRules.current.chosen?
    assert_not Setting.exists?(key: PayRules::KEY, tenant_id: Current.tenant_id)
  end

  test 'admin keys come from the linked sign-in account role' do
    admin = People::Employee.create!(user: @owner, first_name: 'Owner', last_name: 'Admin', employment_type: 'full_time')
    staff_user = User.create!(tenant: Current.tenant, email: 'pay-rules-staff@example.com', role: 'manager', password: 'password')
    staff = People::Employee.create!(user: staff_user, first_name: 'Staff', last_name: 'Member', employment_type: 'part_time')
    unlinked = People::Employee.create!(first_name: 'No', last_name: 'Login', employment_type: 'part_time')
    shifts = [admin, staff, unlinked].map { |worker| ClockShift.new(employee: worker, employee_key: worker.id.to_s) }
    assert_equal Set[admin.id.to_s], PayRules.admin_keys(shifts)
  end
end
