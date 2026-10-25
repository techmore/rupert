# frozen_string_literal: true

require 'test_helper'

# PayrollCalculator reads overtime from PayRules (off by default) and fills a
# flat 15% placeholder deduction; it never invents tax rules.
class PayrollCalculatorTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @employee = People::Employee.create!(first_name: 'Calc', last_name: 'Worker', employee_number: 'PC1')
    People::PayRate.create!(employee: @employee, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-07-01')
    # Thursday 2026-07-23 to Wednesday 2026-08-05: two default Thursday–Wednesday work weeks.
    @sheet = People::Timesheet.create!(employee: @employee, period_start: '2026-07-23', period_end: '2026-08-05')
  end

  teardown { Current.reset }

  def add(day, hours, type = 'regular')
    @sheet.entries.create!(worked_on: Date.parse(day), hours: hours, work_type: type)
  end

  def generate(from = '2026-07-23', to = '2026-08-05')
    @sheet.submit! if @sheet.may_submit?
    @sheet.approve! if @sheet.may_approve?
    run = People::PayRun.create!(name: "Run #{from}", period_start: from, period_end: to)
    People::PayrollCalculator.generate!(run)
    run.payslips.first
  end

  # Week 1 (Thu 07-23..Wed 07-29): 45 regular + 2 marked overtime = 47 worked.
  # Week 2 (Thu 07-30..Wed 08-05): 38 regular + 8 PTO.
  def two_weeks
    %w[2026-07-23 2026-07-24 2026-07-25 2026-07-26 2026-07-27].each { |day| add(day, 9) }
    add('2026-07-28', 2, 'overtime')
    %w[2026-07-30 2026-07-31 2026-08-01 2026-08-02].each { |day| add(day, 9.5) }
    add('2026-08-03', 8, 'pto')
  end

  test 'overtime is off by default, so every hour including marked overtime is straight time' do
    two_weeks
    slip = generate
    assert_equal 93, slip.hours
    assert_equal 93 * 2000, slip.gross_cents
    assert_equal (93 * 2000 * 0.15).round, slip.deductions_cents
    assert_equal slip.gross_cents - slip.deductions_cents, slip.net_cents
  end

  test 'when turned on, worked hours over the threshold in each work week earn the multiplier' do
    PayRules.save!({ overtime_enabled: true }, actor: @user)
    two_weeks
    slip = generate
    # Week 1: 7 h over 40 at 1.5×. Week 2: 38 worked (PTO does not count toward overtime).
    assert_equal (93 * 2000) + (7 * 2000 * 0.5), slip.gross_cents
  end

  test 'the threshold, multiplier and work week start come from the pay rules' do
    PayRules.save!({ pay_period: 'weekly', week_start_day: 'monday', overtime_enabled: true,
                     overtime_threshold_hours: 30, overtime_multiplier: '2' }, actor: @user)
    two_weeks
    slip = generate
    # Monday weeks: 07-20..07-26 has 36 h (6 over), 07-27..08-02 has 9 + 2 + 38 = 49 h (19 over),
    # 08-03..08-09 has only PTO.
    assert_equal (93 * 2000) + (25 * 2000), slip.gross_cents
  end

  test 'a week that straddles the pay run only counts days inside the run' do
    PayRules.save!({ overtime_enabled: true }, actor: @user)
    two_weeks
    slip = generate('2026-07-26', '2026-07-29')
    # Inside the run: 9 + 9 + 2 = 20 worked hours, under the threshold.
    assert_equal 20 * 2000, slip.gross_cents
  end

  test 'salaried pay ignores overtime' do
    @employee.pay_rates.destroy_all
    People::PayRate.create!(employee: @employee, pay_type: 'salary', annual_salary_cents: 5_200_000, effective_on: '2026-07-01')
    PayRules.save!({ overtime_enabled: true }, actor: @user)
    two_weeks
    slip = generate
    assert_equal (5_200_000 * 14 / 364.0).round, slip.gross_cents
  end

  test 'a hand-entered deduction is kept and only empty ones get the placeholder estimate' do
    two_weeks
    slip = generate
    slip.update!(deductions_cents: 1234, net_cents: slip.gross_cents - 1234)
    People::PayrollCalculator.apply_default_deductions(slip.pay_run)
    assert_equal 1234, slip.reload.deductions_cents
  end
end
