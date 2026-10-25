# frozen_string_literal: true

require 'test_helper'

class EmployeePayWeekTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    # A cashier: administrators earn no commission or tips (#423).
    @user = User.create!(tenant: Current.tenant, email: 'employee_pay_week-worker@example.com', role: 'cashier', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'First', last_name: 'Worker', employment_type: 'part_time')
    @second_user = User.create!(tenant: Current.tenant, email: 'second-pay-week@example.com', role: 'cashier', password: 'password')
    @second = People::Employee.create!(user: @second_user, first_name: 'Second', last_name: 'Worker', employment_type: 'part_time')
    People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-01-01')
    shift(@worker, @user, '09:00', '12:00')
    shift(@second, @second_user, '10:00', '11:00')
  end

  teardown { Current.reset }

  test 'weeks run Thursday to Wednesday' do
    assert_equal Date.new(2026, 10, 8), EmployeePayWeek.week_start(Date.new(2026, 10, 14))
    assert_equal Date.new(2026, 10, 15), EmployeePayWeek.week_start(Date.new(2026, 10, 15))
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_equal [Date.new(2026, 10, 8), Date.new(2026, 10, 14)], [pay.start_date, pay.end_date]
  end

  test 'shows hours, rate, base pay, commission and a shared tip for the chosen week' do
    sale('10:30', tip: 600)
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_in_delta 3.0, pay.hours, 0.001
    assert_equal 2000, pay.hourly_rate_cents
    assert_equal 6000, pay.base_cents
    assert_equal 100, pay.commission_cents
    assert_equal 300, pay.tip_cents
    assert_equal 6400, pay.total_cents
  end

  test 'a different week has no hours or sales' do
    sale('10:30')
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 17))
    assert_equal 0, pay.hours
    assert_equal 0, pay.commission_cents
  end

  test 'base pay is unavailable without a pay rate' do
    pay = EmployeePayWeek.new(employee: @second, week_of: Date.new(2026, 10, 10))
    assert_nil pay.base_cents
    assert_includes pay.notes.join, 'No pay rate'
  end

  test 'an administrator gets no commission or tip share, and the tip goes to the non-admins on shift' do
    admin_user = User.create!(tenant: Current.tenant, email: 'admin-pay-week@example.com', role: 'admin', password: 'password')
    admin = People::Employee.create!(user: admin_user, first_name: 'Owner', last_name: 'Admin', employment_type: 'full_time')
    shift(admin, admin_user, '09:30', '11:30')
    sale('10:30', tip: 600)
    pay = EmployeePayWeek.new(employee: admin, week_of: Date.new(2026, 10, 10))
    assert pay.admin?
    assert_in_delta 2.0, pay.hours, 0.001
    assert_equal [0, 0], [pay.commission_cents, pay.tip_cents]
    assert_includes pay.notes.join, 'administrator'
    worker = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_equal [100, 300], [worker.commission_cents, worker.tip_cents], 'split two ways, not three'
  end

  test 'a worker with no linked sign-in is not an admin' do
    assert_not PayRules.admin_employee?(People::Employee.new(first_name: 'No', last_name: 'Login', employment_type: 'part_time'))
  end

  test 'punch times are used as recorded, never rounded' do
    ClockShift.create!(user: @second_user, employee: @second, employee_key: @second.id.to_s, employee_name: @second.name,
      employment_type: @second.employment_type, started_at: Time.zone.parse('2026-10-11 09:07:13'),
      ended_at: Time.zone.parse('2026-10-11 09:59:58'), request_token: SecureRandom.uuid)
    pay = EmployeePayWeek.new(employee: @second, week_of: Date.new(2026, 10, 10))
    assert_in_delta 1.0 + (3165 / 3600.0), pay.hours, 0.000001
  end

  test 'overtime is off by default and paid at the multiplier over the threshold when turned on' do
    long_week
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_in_delta 45.0, pay.hours, 0.001
    assert_equal 0, pay.overtime_hours
    assert_equal 90_000, pay.base_cents
    PayRules.save!({ overtime_enabled: true }, actor: @user)
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_in_delta 5.0, pay.overtime_hours, 0.001
    assert_equal 90_000 + 5000, pay.base_cents, '5 hours at an extra half of $20'
    assert_not PayRules.current.chosen?, 'saving overtime alone does not choose the pay period'
  end

  test 'every two weeks: the period runs 14 days from the anchor and overtime is counted per work week' do
    PayRules.save!({ pay_period: 'biweekly', week_start_day: 'thursday', anchor_date: '2026-10-01', overtime_enabled: true }, actor: @user)
    long_week
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_equal [Date.new(2026, 10, 1), Date.new(2026, 10, 14)], [pay.start_date, pay.end_date]
    assert_in_delta 5.0, pay.overtime_hours, 0.001, 'only the second week is over 40'
    assert_equal Date.new(2026, 10, 8), EmployeePayWeek.week_start(Date.new(2026, 10, 10)), 'work weeks stay seven days'
  end

  test 'the chosen start day moves the week' do
    PayRules.save!({ pay_period: 'weekly', week_start_day: 'monday' }, actor: @user)
    pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    assert_equal [Date.new(2026, 10, 5), Date.new(2026, 10, 11)], [pay.start_date, pay.end_date]
    assert_in_delta 3.0, pay.hours, 0.001
  end

  private

  # 45 hours from Thursday Oct 8 to Monday Oct 12 (the setup shift adds 3 on Saturday).
  def long_week
    { '2026-10-08' => 10, '2026-10-09' => 10, '2026-10-11' => 12, '2026-10-12' => 10 }.each do |day, length|
      started = Time.zone.parse("#{day} 08:00")
      ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
        employment_type: @worker.employment_type, started_at: started, ended_at: started + length.hours, request_token: SecureRandom.uuid)
    end
  end

  def shift(worker, user, started, ended)
    ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s, employee_name: worker.name,
      employment_type: worker.employment_type, started_at: Time.zone.parse("2026-10-10 #{started}"),
      ended_at: Time.zone.parse("2026-10-10 #{ended}"), request_token: SecureRandom.uuid)
  end

  def sale(time, tip: 0)
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse("2026-10-10 #{time}"),
      gross_cents: 11_000, tax_cents: 1000, tip_cents: tip, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!
    order.order_lines.create!(name: 'Merchandise', unit_cents: 10_000, quantity: 1, line_cents: 10_000)
    order.payments.create!(method: 'card', amount_cents: 11_000, status: 'completed', paid_at: order.occurred_at)
  end
end
