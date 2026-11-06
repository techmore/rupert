# frozen_string_literal: true

require 'test_helper'

# Give away, swap and pick up: guardrails, approval policy, the manager review page and the
# employee pages.
class ShiftTradesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'trade-manager@example.com', password: 'password123', role: 'manager', name: 'Mo Manager')
    @alex_user = User.create!(tenant: @tenant, email: 'trade-alex@example.com', password: 'password123', role: 'employee', name: 'Alex')
    @sam_user = User.create!(tenant: @tenant, email: 'trade-sam@example.com', password: 'password123', role: 'employee', name: 'Sam')
    @alex = People::Employee.create!(first_name: 'Alex', last_name: 'Planned', user: @alex_user)
    @sam = People::Employee.create!(first_name: 'Sam', last_name: 'Taker', user: @sam_user)
    @day = Date.current + 10
    @shift = @alex.scheduled_shifts.create!(starts_at: @day.in_time_zone + 9.hours, ends_at: @day.in_time_zone + 17.hours, published_at: Time.current, role_label: 'Counter')
  end

  teardown { Current.reset }

  def sign_in(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  test 'give away: colleague takes it, manager approves, the shift moves and both are told' do
    sign_in(@alex_user)
    get employee_schedule_path(week: @day.beginning_of_week.iso8601)
    assert_select "[data-my-shift='#{@shift.id}']"
    assert_difference -> { People::ShiftTrade.count }, 1 do
      post employee_trades_path, params: { kind: 'give', shift_id: @shift.id }
    end
    trade = People::ShiftTrade.sole
    assert_equal 'open', trade.status
    assert Notification.where(user_id: @sam_user.id, kind: 'trade_offers').exists?, 'colleagues are told about the offer'

    sign_in(@sam_user)
    get employee_trades_path
    assert_select "[data-offer='#{trade.id}']"
    post accept_employee_trade_path(trade)
    assert_redirected_to employee_trades_path
    assert_equal 'accepted', trade.reload.status
    assert_equal @alex.id, @shift.reload.employee_id, 'nothing moves before a manager approves'
    assert Notification.where(user_id: @manager.id, kind: 'approvals').exists?

    sign_in(@manager)
    get people_shift_trades_path
    assert_select "a[href='#{people_shift_trade_path(trade)}']"
    post approve_people_shift_trade_path(trade)
    assert_redirected_to people_shift_trades_path
    assert_equal 'approved', trade.reload.status
    assert_equal @sam.id, @shift.reload.employee_id
    assert Notification.where(user_id: @alex_user.id, kind: 'approvals').exists?
    assert Notification.where(user_id: @sam_user.id, kind: 'approvals').exists?
  end

  test 'pick up an open shift applies immediately when the store does not require approval' do
    open_shift = People::ScheduledShift.create!(starts_at: (@day + 1).in_time_zone + 9.hours, ends_at: (@day + 1).in_time_zone + 13.hours, published_at: Time.current)
    TimeRules.save!({ 'trade_requires_approval' => '0' })
    sign_in(@sam_user)
    get employee_schedule_path(week: @day.beginning_of_week.iso8601)
    assert_select "[data-open-shift='#{open_shift.id}']"
    post employee_trades_path, params: { kind: 'pickup', shift_id: open_shift.id }
    assert_equal @sam.id, open_shift.reload.employee_id
    assert_equal 'approved', People::ShiftTrade.sole.status
  end

  test 'guardrails block double-booking, overtime, minors, time off and short notice' do
    # Double-booked.
    @sam.scheduled_shifts.create!(starts_at: @day.in_time_zone + 12.hours, ends_at: @day.in_time_zone + 20.hours, published_at: Time.current)
    checks = People::TradeGuardrails.check(@shift, @sam)
    assert_includes checks.map { |c| c['code'] }, 'double_booked'
    @sam.scheduled_shifts.delete_all

    # Over the weekly threshold (40 h planned already).
    week_start = PayRules.current.week_start(@day)
    5.times { |i| @sam.scheduled_shifts.create!(starts_at: (week_start + i).in_time_zone + 1.hour, ends_at: (week_start + i).in_time_zone + 9.hours) }
    assert_includes People::TradeGuardrails.check(@shift, @sam).map { |c| c['code'] }, 'overtime'
    @sam.scheduled_shifts.delete_all

    # Minor outside the 7 AM – 7 PM window.
    @sam.update!(date_of_birth: 16.years.ago.to_date)
    late = @alex.scheduled_shifts.create!(starts_at: (@day + 2).in_time_zone + 15.hours, ends_at: (@day + 2).in_time_zone + 21.hours, published_at: Time.current)
    assert_includes People::TradeGuardrails.check(late, @sam).map { |c| c['code'] }, 'minor_hours'
    @sam.update!(date_of_birth: 30.years.ago.to_date)

    # Approved time off.
    @sam.leave_requests.create!(leave_type: 'vacation', starts_on: @day, ends_on: @day, hours: 8).approve!
    assert_includes People::TradeGuardrails.check(@shift, @sam).map { |c| c['code'] }, 'time_off'
    @sam.leave_requests.delete_all

    # Short notice.
    soon = @alex.scheduled_shifts.create!(starts_at: 1.hour.from_now, ends_at: 5.hours.from_now, published_at: Time.current)
    assert_includes People::TradeGuardrails.check(soon, @sam).map { |c| c['code'] }, 'notice'

    # Clean: a warning for an availability block, nothing blocking.
    @sam.availabilities.create!(weekday: @day.wday, start_minute: 0, end_minute: 1440, kind: 'unavailable')
    checks = People::TradeGuardrails.check(@shift, @sam)
    assert_equal ['availability'], checks.map { |c| c['code'] }
    assert checks.none? { |c| c['level'] == 'block' }

    # A blocked acceptance is refused with the reason, and the manager cannot approve around it.
    @sam.availabilities.delete_all
    sign_in(@alex_user)
    post employee_trades_path, params: { kind: 'give', shift_id: @shift.id }
    trade = People::ShiftTrade.sole
    @sam.scheduled_shifts.create!(starts_at: @day.in_time_zone + 12.hours, ends_at: @day.in_time_zone + 20.hours, published_at: Time.current)
    sign_in(@sam_user)
    post accept_employee_trade_path(trade)
    assert_redirected_to employee_trades_path
    assert_includes flash[:alert], 'already has a shift'
    assert_equal 'open', trade.reload.status
  end

  test 'swap exchanges both shifts after the colleague agrees and a manager approves' do
    sam_shift = @sam.scheduled_shifts.create!(starts_at: (@day + 1).in_time_zone + 9.hours, ends_at: (@day + 1).in_time_zone + 17.hours, published_at: Time.current)
    sign_in(@alex_user)
    post employee_trades_path, params: { kind: 'swap', shift_id: @shift.id, counter_shift_id: sam_shift.id }
    trade = People::ShiftTrade.sole
    assert_equal 'swap', trade.kind
    assert_equal @sam.id, trade.to_employee_id
    assert Notification.where(user_id: @sam_user.id, kind: 'trade_offers').exists?
    sign_in(@sam_user)
    post accept_employee_trade_path(trade)
    assert_equal 'accepted', trade.reload.status
    sign_in(@manager)
    post approve_people_shift_trade_path(trade)
    assert_equal @sam.id, @shift.reload.employee_id
    assert_equal @alex.id, sam_shift.reload.employee_id
  end

  test 'a manager involved in the trade cannot review it; denial keeps the shift and carries a note' do
    manager_worker = People::Employee.create!(first_name: 'Mo', last_name: 'Manager', user: @manager)
    own = manager_worker.scheduled_shifts.create!(starts_at: (@day + 3).in_time_zone + 9.hours, ends_at: (@day + 3).in_time_zone + 17.hours, published_at: Time.current)
    sign_in(@manager)
    post employee_trades_path, params: { kind: 'give', shift_id: own.id }
    trade = People::ShiftTrade.sole
    sign_in(@sam_user)
    post accept_employee_trade_path(trade)
    sign_in(@manager)
    post approve_people_shift_trade_path(trade)
    assert_includes flash[:alert], 'Another manager'
    assert_equal 'accepted', trade.reload.status

    other_manager = User.create!(tenant: @tenant, email: 'trade-manager2@example.com', password: 'password123', role: 'manager')
    sign_in(other_manager)
    post deny_people_shift_trade_path(trade), params: { note: 'Need you on the floor that day' }
    assert_equal 'denied', trade.reload.status
    assert_equal manager_worker.id, own.reload.employee_id
    assert_includes Notification.where(user_id: @sam_user.id, kind: 'approvals').last.body, 'Need you'
  end

  test 'cancel and expiry close trades; drafts and past shifts cannot be traded' do
    sign_in(@alex_user)
    post employee_trades_path, params: { kind: 'give', shift_id: @shift.id }
    trade = People::ShiftTrade.sole
    post cancel_employee_trade_path(trade)
    assert_equal 'cancelled', trade.reload.status
    draft = @alex.scheduled_shifts.create!(starts_at: (@day + 4).in_time_zone + 9.hours, ends_at: (@day + 4).in_time_zone + 17.hours)
    post employee_trades_path, params: { kind: 'give', shift_id: draft.id }
    assert_response :not_found
    post employee_trades_path, params: { kind: 'give', shift_id: @shift.id }
    stale = People::ShiftTrade.order(:id).last
    travel_to(@day.in_time_zone + 10.hours) { People::ShiftTradeWorkflow.expire_stale! }
    assert_equal 'expired', stale.reload.status
  end
end
