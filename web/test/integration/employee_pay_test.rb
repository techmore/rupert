# frozen_string_literal: true

require 'test_helper'

# The worker's own Pay page: hours, estimated gross, tips with Estimated/Final, next payday, cash
# tips in two taps, Spanish, and nobody else's rows ever.
class EmployeePayTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, name: 'Pay Worker', email: 'pay-worker@example.com', role: 'employee', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'Pay', last_name: 'Worker', employment_type: 'part_time')
    People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-01-01')
    @other_user = User.create!(tenant: @tenant, name: 'Other', email: 'other-pay@example.com', role: 'employee', password: 'password')
    @other = People::Employee.create!(user: @other_user, first_name: 'Other', last_name: 'Worker', employment_type: 'part_time')
    @at = Time.zone.parse('2026-11-05 09:00')
    @shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: 'part_time',
      started_at: @at, ended_at: @at + 8.hours, request_token: SecureRandom.uuid, source: 'pos')
    @shift.breaks.create!(kind: 'meal', paid: false, started_at: @at + 3.hours, ended_at: @at + 3.5.hours)
    TipAllocation.create!(employee: @worker, clock_shift: @shift, source_kind: 'dejavoo_feed_event', source_id: 1, tip_method: 'pool', status: 'estimated',
      amount_cents: 450, gross_tip_cents: 900, share_count: 2, occurred_at: @at + 2.hours, business_date: @at.to_date, evidence: 'time_register')
    TipAllocation.create!(employee: @worker, clock_shift: @shift, source_kind: 'dejavoo_feed_event', source_id: 2, tip_method: 'pool', status: 'settled',
      amount_cents: 300, gross_tip_cents: 300, share_count: 1, occurred_at: @at + 4.hours, business_date: @at.to_date, evidence: 'checkout', settlement_ref: 'dejavoo-batch:1')
    TipAllocation.create!(employee: @other, source_kind: 'manual', tip_method: 'adjustment', status: 'settled', amount_cents: 9999,
      occurred_at: @at + 4.hours, business_date: @at.to_date)
    sign_in(@user)
  end

  teardown { Current.reset }

  test 'shows my period figures, tips with their state and next payday, never another worker' do
    travel_to Time.zone.parse('2026-11-06 12:00') do
      get employee_pay_path
      assert_response :success
      assert_select 'h1', 'Pay'
      assert_select '.stat', text: /Hours\s*7\.50 h/
      assert_select '.stat', text: /Tips\s*\$7\.50/
      assert_select '.stat', text: /Estimated gross\s*\$157\.50/
      assert_select '.pill-taupe', text: 'Estimated'
      assert_select '.pill-fern', text: 'Final'
      assert_select 'body', text: /Next payday/
      assert_select 'body', text: /shared with 1 other person/
      assert_no_match '99.99', response.body
      get employee_pay_path(period: '2026-10-01')
      assert_response :success
      assert_select '.stat', text: /Tips\s*\$0\.00/
    end
  end

  test 'cash tips are declared in two taps and replace an earlier figure for the same shift' do
    travel_to Time.zone.parse('2026-11-06 12:00') do
      post declare_employee_tips_path, params: { cash_tips: { amount: '18.50', shift_id: @shift.id } }
      assert_redirected_to employee_pay_path(anchor: 'cash-tips')
      assert_equal 1850, TipAllocation.where(employee_id: @worker.id, source_kind: 'declared').sum(:amount_cents)
      post declare_employee_tips_path, params: { cash_tips: { amount: '20', shift_id: @shift.id } }
      assert_equal 2000, TipAllocation.where(employee_id: @worker.id, source_kind: 'declared').sum(:amount_cents)
      assert_equal 3, TipAllocation.where(employee_id: @worker.id, source_kind: 'declared').count, 'the ledger keeps the earlier figure and its reversal'
      post declare_employee_tips_path, params: { cash_tips: { amount: '5', shift_id: ClockShift.create!(user: @other_user, employee: @other, employee_key: @other.id.to_s,
        employee_name: @other.name, employment_type: 'part_time', started_at: @at, ended_at: @at + 1.hour, request_token: SecureRandom.uuid).id } }
      follow_redirect!
      assert_select '.flash-alert', /not yours/
      get employee_pay_path
      assert_select '.stat', text: /Tips\s*\$27\.50/
    end
  end

  test 'a locked pay period shows Final and refuses new cash tips' do
    travel_to Time.zone.parse('2026-11-06 12:00') do
      PayPeriod.for_date(Date.new(2026, 11, 5)).lock!(by: users(:regular_user))
      get employee_pay_path
      assert_select 'p', text: /Final/
      assert_select '.stat', text: /Gross pay/
      post declare_employee_tips_path, params: { cash_tips: { amount: '3', shift_id: @shift.id } }
      follow_redirect!
      assert_select '.flash-alert', /locked/
    end
  end

  test 'renders in Spanish for a worker whose language is Spanish' do
    @worker.update!(locale: 'es')
    get employee_pay_path
    assert_select 'h1', 'Pago'
    assert_select 'body', text: /Próximo día de pago/
  end

  test 'a manager without a worker record is sent back to the staff home' do
    sign_in(users(:regular_user))
    get employee_pay_path
    assert_redirected_to employee_app_path
  end
end
