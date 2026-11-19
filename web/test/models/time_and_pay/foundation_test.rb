# frozen_string_literal: true

require 'test_helper'

# The time & pay foundation: PINs, breaks, trusted devices, pay-period locks, the tip ledger and
# per-store time rules (docs/time-and-pay/ARCHITECTURE.md).
class TimeAndPayFoundationTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    Current.user = users(:regular_user)
    @user = User.create!(tenant: @tenant, name: 'Pin Worker', email: 'pin-worker@example.com', role: 'employee', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'Pin', last_name: 'Worker', employment_type: 'part_time')
  end

  teardown { Current.reset }

  test 'pin is stored as a digest, verified, and locked after repeated failures' do
    assert_not @worker.pin_set?
    assert_raises(ArgumentError) { @worker.set_pin!('12') }
    assert_raises(ArgumentError) { @worker.set_pin!('1111') }
    @worker.set_pin!('2580')
    assert @worker.pin_set?
    assert_not_equal '2580', @worker.pin_digest
    assert @worker.verify_pin('2580')
    rules = TimeRules.for
    rules.pin_lockout_attempts.times { assert_not @worker.verify_pin('0000') }
    assert @worker.reload.pin_locked?
    assert_not @worker.verify_pin('2580'), 'a locked PIN refuses even the right digits'
    travel(rules.pin_lockout_minutes.minutes + 1.second) { assert @worker.verify_pin('2580') }
  end

  test 'breaks live inside the shift and unpaid meals reduce paid hours' do
    shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', started_at: 8.hours.ago, ended_at: 1.hour.ago, request_token: SecureRandom.uuid, source: 'pos')
    assert_equal 7, shift.hours.round
    meal = shift.breaks.create!(kind: 'meal', paid: false, started_at: 5.hours.ago, ended_at: 4.5.hours.ago)
    shift.breaks.create!(kind: 'rest', started_at: 3.hours.ago, ended_at: 2.hours.ago + 50.minutes)
    assert_equal 30, meal.minutes
    assert_in_delta 6.5, shift.reload.paid_hours, 0.01
    bad = shift.breaks.build(kind: 'rest', started_at: 10.hours.ago)
    assert_not bad.valid?
    assert_raises(ActiveRecord::RecordInvalid) { shift.breaks.create!(kind: 'rest', started_at: 9.hours.ago) }
  end

  # FLSA, 29 CFR 785.18-785.19: short breaks are hours worked; only a real meal period may be unpaid.
  test 'a punched meal of 20 minutes or less is paid time; a longer one is unpaid' do
    at = Time.zone.parse('2026-11-05 09:00')
    shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', started_at: at, ended_at: at + 8.hours, request_token: SecureRandom.uuid, source: 'pos')
    short = shift.breaks.create!(kind: 'meal', paid: false, started_at: at + 2.hours, ended_at: at + 2.hours + 12.minutes)
    edge = shift.breaks.create!(kind: 'meal', paid: false, started_at: at + 3.hours, ended_at: at + 3.hours + 20.minutes)
    rules = TimeRules.for
    assert_not rules.meal_break_paid?, 'meals are unpaid by default'
    assert_not short.unpaid?(rules)
    assert_not edge.unpaid?(rules), 'exactly 20 minutes is still a short break'
    assert_equal 0, shift.reload.unpaid_break_seconds
    assert_in_delta 8.0, shift.paid_hours, 0.001
    assert_in_delta 8.0, shift.paid_hours_between(at.beginning_of_day, at.beginning_of_day + 1.day), 0.001

    long = shift.breaks.create!(kind: 'meal', paid: false, started_at: at + 5.hours, ended_at: at + 5.hours + 20.minutes + 1.second)
    assert long.unpaid?(rules)
    real = shift.breaks.create!(kind: 'meal', paid: false, started_at: at + 6.hours, ended_at: at + 6.5.hours)
    assert real.unpaid?(rules)
    assert_equal (20.minutes + 1.second + 30.minutes).to_i, shift.reload.unpaid_break_seconds.to_i
    assert_in_delta 8.0 - (50.minutes + 1.second) / 3600.0, shift.paid_hours, 0.001
    assert_in_delta shift.paid_hours, shift.paid_hours_between(at.beginning_of_day, at.beginning_of_day + 1.day), 0.001
  end

  test 'the short-break floor also covers rest breaks a store marked unpaid, and a paid-meal store is unchanged' do
    at = Time.zone.parse('2026-11-05 09:00')
    shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', started_at: at, ended_at: at + 8.hours, request_token: SecureRandom.uuid, source: 'pos')
    shift.breaks.create!(kind: 'rest', started_at: at + 1.hour, ended_at: at + 1.hour + 10.minutes)
    shift.breaks.create!(kind: 'rest', started_at: at + 4.hours, ended_at: at + 4.hours + 25.minutes)
    shift.breaks.create!(kind: 'meal', started_at: at + 6.hours, ended_at: at + 6.hours + 45.minutes)
    TimeRules.save!({ 'rest_break_paid' => '0', 'meal_break_paid' => '1' })
    assert_equal 25.minutes.to_i, shift.reload.unpaid_break_seconds.to_i, 'only the 25-minute unpaid rest break comes off'
    assert_in_delta 8.0 - 25 / 60.0, shift.paid_hours, 0.001
  end

  test 'a short meal is judged by its whole length when a day boundary clips it, and an open meal turns unpaid after 20 minutes' do
    start = Time.zone.parse('2026-11-05 20:00')
    midnight = Time.zone.parse('2026-11-06 00:00')
    shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', started_at: start, ended_at: start + 8.hours, request_token: SecureRandom.uuid, source: 'pos')
    shift.breaks.create!(kind: 'meal', paid: false, started_at: midnight - 15.minutes, ended_at: midnight + 15.minutes)
    assert_in_delta 3.75, shift.paid_hours_between(midnight - 1.day, midnight), 0.001, '30-minute meal: its 15 minutes before midnight are unpaid'
    assert_in_delta 3.75, shift.paid_hours_between(midnight, midnight + 1.day), 0.001

    open_shift = ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: 'part_time', started_at: start + 1.day, request_token: SecureRandom.uuid, source: 'pos')
    open_shift.breaks.create!(kind: 'meal', paid: false, started_at: start + 1.day + 2.hours)
    assert_equal 0, open_shift.unpaid_break_seconds(at: start + 1.day + 2.hours + 10.minutes)
    assert_equal 35.minutes.to_i, open_shift.unpaid_break_seconds(at: start + 1.day + 2.hours + 35.minutes).to_i
  end

  test 'trusted clock devices authenticate by digest and can be revoked' do
    device, secret = ClockDevice.register!(name: 'Front register', registered_by: Current.user)
    assert secret.start_with?(ClockDevice::TOKEN_PREFIX)
    assert_equal device, ClockDevice.authenticate(secret)
    assert_nil ClockDevice.authenticate('nope')
    device.revoke!
    assert_nil ClockDevice.authenticate(secret)
  end

  test 'pay periods follow the pay rules and lock out late tips into the next open period' do
    period = PayPeriod.for_date(Date.new(2026, 11, 6))
    assert_equal PayRules.current.period_start(Date.new(2026, 11, 6)), period.starts_on
    assert period.open?
    allocation = TipAllocation.create!(employee: @worker, source_kind: 'manual', tip_method: 'pool', amount_cents: 500,
      occurred_at: Time.zone.parse('2026-11-06 12:00'), business_date: Date.new(2026, 11, 6), location_id: nil)
    assert_equal period.starts_on, allocation.pay_period_start
    period.lock!(by: Current.user)
    assert_not PayPeriod.open_for?(Date.new(2026, 11, 6))
    late = TipAllocation.create!(employee: @worker, source_kind: 'manual', tip_method: 'pool', amount_cents: 300,
      occurred_at: Time.zone.parse('2026-11-06 18:00'), business_date: Date.new(2026, 11, 6))
    assert_equal 'carried', late.status
    assert_operator late.pay_period_start, :>, period.ends_on
    reversal = allocation.reverse!(reason: 'refunded')
    assert_equal(-500, reversal.amount_cents)
    assert_equal 'reversed', allocation.reload.status
    assert_equal reversal, allocation.reverse!(reason: 'again'), 'reversing twice is a no-op'
  end

  test 'time rules merge preset, workspace default and store overrides' do
    assert_equal 'pool', TimeRules.for.tip_method
    assert_equal 0, TimeRules.for.rounding_minutes
    TimeRules.save!({ 'preset' => 'california', 'rounding_minutes' => '5' })
    rules = TimeRules.for
    assert rules.daily_overtime?
    assert_equal 5, rules.rounding_minutes
    location = Location.create!(name: 'Second store', source: 'rupert', externalId: 'second-store', active: true)
    TimeRules.save!({ 'meal_break_minutes' => '45', 'rounding_minutes' => '5' }, location_id: location.id)
    assert_equal 45, TimeRules.for(location).meal_break_minutes
    assert_equal 30, TimeRules.for.meal_break_minutes
    assert_equal({ 'meal_break_minutes' => 45 }, TimeRules.stored['locations'][location.id.to_s], 'overrides equal to the default are dropped')
    assert_raises(TimeRules::Invalid) { TimeRules.save!({ 'rounding_minutes' => '7' }) }
    assert_equal Time.zone.parse('2026-11-06 09:05'), rules.round_punch(Time.zone.parse('2026-11-06 09:07:10'))
  end

  test 'open shifts have no employee and trades allow one live request per shift' do
    open_shift = People::ScheduledShift.create!(starts_at: 2.days.from_now.change(hour: 9), ends_at: 2.days.from_now.change(hour: 17), role_label: 'Counter')
    assert open_shift.open?
    trade = People::ShiftTrade.create!(scheduled_shift: open_shift, kind: 'pickup', to_employee: @worker, requested_by: @user)
    assert trade.live?
    assert_not People::ShiftTrade.new(scheduled_shift: open_shift, kind: 'pickup', to_employee: @worker).valid?
  end

  test 'push devices register by token digest and move between accounts' do
    device = PushDevice.register!(user: @user, platform: 'ios', token: 'abc123', environment: 'sandbox')
    other = User.create!(tenant: @tenant, name: 'Other', email: 'other-push@example.com', role: 'employee', password: 'password')
    moved = PushDevice.register!(user: other, platform: 'ios', token: 'abc123')
    assert_equal device.id, moved.id
    assert_equal other.id, moved.user_id
    moved.disable!('BadDeviceToken')
    assert_empty PushDevice.active
  end

  test 'minors are detected from the encrypted date of birth and store scope defaults to everywhere' do
    @worker.update!(date_of_birth: 16.years.ago.to_date)
    assert @worker.minor?
    @worker.update!(date_of_birth: 30.years.ago.to_date)
    assert_not @worker.minor?
    assert @worker.works_at?('anything')
    @worker.location_ids = ['loc-1']
    assert_not @worker.works_at?('loc-2')
    assert users(:regular_user).manages_location?('loc-9')
  end
end
