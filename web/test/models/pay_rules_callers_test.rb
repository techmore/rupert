# frozen_string_literal: true

require 'test_helper'

# Every pay estimate asks PayRules for overtime, commission and the work week.
# One scenario, every caller: payroll, the pay week, the work summary, the
# timesheet review flags, the commission preview and timesheet compensation
# must agree with each other and with the rules.
class PayRulesCallersTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = User.create!(tenant: Current.tenant, email: 'pay-rules-callers@example.com', role: 'cashier', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'Rules', last_name: 'Worker', employment_type: 'part_time')
    People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-01-01')
    # 45 hours in the Thursday Oct 8 – Wednesday Oct 14 work week, as clock punches and as one timesheet.
    @sheet = People::Timesheet.create!(employee: @worker, period_start: '2026-10-08', period_end: '2026-10-14')
    { '2026-10-08' => 10, '2026-10-09' => 10, '2026-10-10' => 3, '2026-10-11' => 12, '2026-10-12' => 10 }.each do |day, length|
      started = Time.zone.parse("#{day} 08:00")
      ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
        employment_type: @worker.employment_type, started_at: started, ended_at: started + length.hours, request_token: SecureRandom.uuid)
      @sheet.entries.create!(worked_on: Date.parse(day), hours: length, work_type: 'regular')
    end
  end

  teardown { Current.reset }

  # Base/gross pay per caller for the 45-hour week at $20/hour.
  def figures
    Current.pay_rules = nil
    rules = PayRules.current
    pay_week = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10))
    payroll = People::PayrollCalculator.send(:gross_for, @worker.pay_rate_for(@sheet.period_start, @sheet.period_end), 45.to_d,
      People::PayrollCalculator.send(:overtime_hours, @sheet.entries.group_by(&:worked_on).transform_values { |list| list.to_h { [it.work_type, it.hours] } }, rules),
      nil, rules: rules)
    { pay_week: pay_week.base_cents.to_i, payroll: payroll, overtime_hours: pay_week.overtime_hours.round(6) }
  end

  def flags
    Current.pay_rules = nil
    TimesheetInsights.summaries([@sheet.reload]).fetch(@sheet.id).flags
  end

  test 'overtime is off by default: every caller pays straight time' do
    rules = PayRules.current
    assert_not rules.overtime_enabled?
    assert_equal({ pay_week: 90_000, payroll: 90_000, overtime_hours: 0.0 }, figures)
    assert_equal 1, rules.multiplier_for('overtime')
    assert_equal 0, rules.overtime_premium_cents(0, 2000)
    assert_includes flags, 'Over 40 hours without overtime', 'the review flag reads the same threshold'
  end

  test 'overtime on: hours over the threshold earn the multiplier in every caller' do
    PayRules.save!({ overtime_enabled: true }, actor: @user)
    assert_equal({ pay_week: 95_000, payroll: 95_000, overtime_hours: 5.0 }, figures)
    rules = PayRules.current
    assert_equal BigDecimal('1.5'), rules.multiplier_for('overtime')
    assert_equal 1, rules.multiplier_for('regular')
    overtime_entry = @sheet.entries.create!(worked_on: Date.new(2026, 10, 13), hours: 2, work_type: 'overtime')
    summary = EmployeeWorkSummary.new(employee: @worker, from: Date.new(2026, 10, 8), to: Date.new(2026, 10, 14))
    assert_equal 6000, summary.estimated_cents(overtime_entry), '2 overtime-labelled hours at 1.5 × $20'
  end

  test 'a custom threshold and multiplier move every caller together' do
    PayRules.save!({ overtime_enabled: true, overtime_threshold_hours: '44', overtime_multiplier: '2' }, actor: @user)
    assert_equal({ pay_week: 92_000, payroll: 92_000, overtime_hours: 1.0 }, figures)
    assert_includes flags, 'Over 44 hours without overtime'
    PayRules.save!({ overtime_threshold_hours: '46' }, actor: @user)
    assert_equal({ pay_week: 90_000, payroll: 90_000, overtime_hours: 0.0 }, figures)
    assert_not flags.any? { it.start_with?('Over ') }
  end

  test 'threshold arithmetic keeps each caller number type' do
    rules = PayRules.current
    assert_equal 5.0, rules.hours_over_threshold(45.0)
    assert_kind_of Float, rules.hours_over_threshold(45.0)
    assert_equal BigDecimal('5'), rules.hours_over_threshold(BigDecimal('45'))
    assert_equal 0, rules.hours_over_threshold(BigDecimal('39.5'))
    assert_equal '40', rules.overtime_threshold_label
  end

  test 'commission is 1% in whole cents, identical to the former EmployeePayWeek and TimesheetCompensation rounding' do
    ((0..2_000).to_a + [10_049, 10_050, 10_149, 10_150, 123_456_789]).each do |base|
      assert_equal (base + 50) / 100, PayRules.commission_cents(base), base
      assert_equal (base * 0.01).round, PayRules.commission_cents(base), base
      assert_equal PayRules.commission_cents(base), TimesheetCompensation.calculate(sales_cents: base, card_redemptions: 0)[:commission_cents]
    end
    assert_equal(-2, PayRules.commission_cents(-150), 'a negative half cent rounds away from zero, as Float#round did')
    assert_equal PayRules::COMMISSION_RATE, TimesheetCompensation::COMMISSION_RATE
  end

  test 'commission preview and pay week agree on commission, and admins earn none' do
    admin_user = User.create!(tenant: Current.tenant, email: 'pay-rules-admin@example.com', role: 'admin', password: 'password')
    admin = People::Employee.create!(user: admin_user, first_name: 'Owner', last_name: 'Admin', employment_type: 'full_time')
    ClockShift.create!(user: admin_user, employee: admin, employee_key: admin.id.to_s, employee_name: admin.name, employment_type: admin.employment_type,
      started_at: Time.zone.parse('2026-10-10 08:00'), ended_at: Time.zone.parse('2026-10-10 11:00'), request_token: SecureRandom.uuid)
    order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-10 09:30'),
      gross_cents: 11_050, tax_cents: 1000, tip_cents: 0, currency: 'USD')
    order.aasm.current_state = :paid
    order.save!
    order.order_lines.create!(name: 'Merchandise', unit_cents: 10_050, quantity: 1, line_cents: 10_050)
    order.payments.create!(method: 'card', amount_cents: 11_050, status: 'completed', paid_at: order.occurred_at)

    preview = CommissionPreview.new(start_date: '2026-10-08', end_date: '2026-10-14', source: 'shopify', currency: 'USD')
    worker_row = preview.rows.find { it[:employee_id] == @worker.id }
    admin_row = preview.rows.find { it[:employee_id] == admin.id }
    assert_equal PayRules.commission_cents(10_050), worker_row[:commission_cents]
    assert_equal 101, worker_row[:commission_cents], '$100.50 at 1% is $1.005, rounded half up'
    assert_equal 0, admin_row[:commission_cents]
    assert_equal worker_row[:commission_cents], EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 10)).commission_cents
    assert_equal 0, EmployeePayWeek.new(employee: admin, week_of: Date.new(2026, 10, 10)).commission_cents
    assert PayRules.admin_employee?(admin)
  end

  test 'week_start serves the pay week and the timesheet page views' do
    rules = PayRules.current
    wednesday = Date.new(2026, 10, 14)
    assert_equal Date.new(2026, 10, 8), rules.week_start(wednesday)
    assert_equal Date.new(2026, 10, 8), rules.week_start(wednesday, view: 'thu')
    assert_equal wednesday, rules.week_start(wednesday, view: 'custom')
    assert_equal Date.new(2026, 10, 12), rules.week_start(wednesday, view: 'mon')
    assert_equal EmployeePayWeek.week_start(wednesday), rules.week_start(wednesday)
    PayRules.save!({ pay_period: 'weekly', week_start_day: 'sunday' }, actor: @user)
    Current.pay_rules = nil
    assert_equal Date.new(2026, 10, 11), PayRules.current.week_start(wednesday, view: 'thu'), 'wk=thu follows the chosen start day'
    assert_equal Date.new(2026, 10, 12), PayRules.current.week_start(wednesday, view: 'mon')
  end
end
