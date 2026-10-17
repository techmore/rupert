require 'test_helper'

class EmployeeEarningsPeriodTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @worker = People::Employee.create!(first_name: 'Earnings', last_name: 'Worker')
  end
  teardown { Current.reset }

  def period
    EmployeeEarningsPeriod.new(employee: @worker, period_start: Date.new(2026, 10, 5), period_end: Date.new(2026, 10, 11), hours: 32,
      base_cents: 64000, tips_cents: 9600, store_commission_cents: 6400, online_commission_cents: 3200, bonus_cents: 1600, reviewed_at: Time.current)
  end

  test 'effective hourly rate includes all five components once' do
    record = period
    assert record.valid?, record.errors.full_messages.to_sentence
    assert_equal 84800, record.total_cents
    assert_equal 2650, record.hourly_cents
  end

  test 'zero hours negative earnings and overlapping periods are rejected' do
    record = period
    record.hours = 0
    assert_not record.valid?
    assert_nil record.hourly_cents
    record = period
    record.bonus_cents = -1
    assert_not record.valid?
    period.save!
    assert_not period.valid?
  end

  test 'foreign employee is rejected and demo stays read only' do
    other = Tenant.create!(name: 'Other earnings', subdomain: 'other-earnings')
    record = period
    record.tenant_id = other.id
    assert_not record.valid?
    assert EmployeeEarningsPeriod.demo.readonly?
    assert_equal 2650, EmployeeEarningsPeriod.demo.hourly_cents
  end
end
