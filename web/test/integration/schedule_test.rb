# frozen_string_literal: true

require 'test_helper'

class ScheduleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'schedule-worker@example.com', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Alex', last_name: 'Planned', user: @user)
    @other = People::Employee.create!(first_name: 'Someone', last_name: 'Else')
    @monday = Date.new(2026, 10, 19)
    @mine = @worker.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours, role_label: 'Counter', notes: 'Bring keys')
    @other.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours, role_label: 'PRIVATEOTHER')
  end
  teardown { Current.reset }

  def sign_in(user, password)
    post login_path, params: { email: user.email, password: password }
    Current.tenant = @tenant
  end

  test 'employee sees only their own planned shifts for the chosen week' do
    sign_in(@user, 'password123')
    get employee_schedule_path(week: '2026-10-22')
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_select 'nav[aria-label="My workspace"] a[href=?]', employee_schedule_path
    assert_includes response.body, '9:00 AM – 5:00 PM'
    assert_includes response.body, 'Counter'
    assert_includes response.body, 'Bring keys'
    refute_includes response.body, 'PRIVATEOTHER'
    get employee_schedule_path(week: '2026-10-26')
    assert_includes response.body, 'No shift planned'
    refute_includes response.body, 'Counter'
    get employee_schedule_path(week: 'nonsense')
    assert_redirected_to employee_app_path
  end

  test 'schedule rejects overlaps, reversed times and other-workspace people' do
    overlap = @worker.scheduled_shifts.new(starts_at: @monday.in_time_zone + 16.hours, ends_at: @monday.in_time_zone + 20.hours)
    refute overlap.valid?
    assert_includes overlap.errors.full_messages.to_sentence, 'overlaps'
    refute @worker.scheduled_shifts.new(starts_at: @monday.in_time_zone + 20.hours, ends_at: @monday.in_time_zone + 19.hours).valid?
    refute @worker.scheduled_shifts.new(starts_at: @monday.in_time_zone + 30.hours, ends_at: @monday.in_time_zone + 60.hours).valid?
  end

  test 'administrators plan, edit and remove shifts' do
    admin = users(:regular_user)
    sign_in(admin, 'password')
    get people_scheduled_shifts_path(week: '2026-10-19')
    assert_response :success
    assert_includes response.body, 'Alex Planned'
    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-20T10:00', ends_at: '2026-10-20T14:00', role_label: 'Stock' } }
    end
    assert_response :redirect
    shift = People::ScheduledShift.order(:id).last
    get edit_people_scheduled_shift_path(shift)
    assert_response :success
    patch people_scheduled_shift_path(shift), params: { scheduled_shift: { role_label: 'Floor' } }
    assert_equal 'Floor', shift.reload.role_label
    assert_difference 'People::ScheduledShift.count', -1 do
      delete people_scheduled_shift_path(shift)
    end
  end

  test 'managers can plan shifts; shift leaders only once granted schedule editing' do
    manager = User.create!(tenant: @tenant, email: 'schedule-manager@example.com', password: 'password123', role: 'manager')
    sign_in(manager, 'password123')
    get people_scheduled_shifts_path(week: '2026-10-19')
    assert_response :success
    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-21T10:00', ends_at: '2026-10-21T14:00' } }
    end
    delete logout_path

    leader = User.create!(tenant: @tenant, email: 'schedule-leader@example.com', password: 'password123', role: 'shift_leader')
    sign_in(leader, 'password123')
    assert_no_difference 'People::ScheduledShift.count' do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-22T10:00', ends_at: '2026-10-22T14:00' } }
    end
    refute_includes ModuleRegistry.nav_for(leader).map(&:key), 'schedule'
    leader.user_permissions.create!(tenant_id: @tenant.id, permission: 'schedule.write', enabled: true)
    assert_includes ModuleRegistry.nav_for(leader.reload).map(&:key), 'schedule'
    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-22T10:00', ends_at: '2026-10-22T14:00' } }
    end
  end

  test 'the Employee app shows the next planned shift' do
    travel_to @monday.in_time_zone + 8.hours
    sign_in(@user, 'password123')
    get employee_app_path
    assert_response :success
    assert_select '.card-title', 'Next shift'
    assert_includes response.body, 'Today · 9:00 AM – 5:00 PM · Counter'
    travel_to @monday.in_time_zone + 18.hours
    get employee_app_path
    assert_includes response.body, 'No shift planned yet.'
  end

  test 'employees cannot open the manager schedule' do
    sign_in(@user, 'password123')
    get people_scheduled_shifts_path
    refute_equal 200, response.status
    assert_no_difference 'People::ScheduledShift.count' do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: '2026-10-21T10:00', ends_at: '2026-10-21T14:00' } }
    end
  end
  test 'copy last week copies shifts forward and skips overlaps' do
    sign_in(users(:regular_user), 'password')
    next_monday = @monday + 7
    # Alex already works Monday morning next week; the copy of the same shift would overlap.
    @worker.scheduled_shifts.create!(starts_at: next_monday.in_time_zone + 8.hours, ends_at: next_monday.in_time_zone + 12.hours)
    assert_difference 'People::ScheduledShift.count', 1 do
      post copy_last_week_people_scheduled_shifts_path(week: next_monday.iso8601)
    end
    assert_redirected_to people_scheduled_shifts_path(week: next_monday.iso8601)
    assert_includes flash[:notice], 'Copied 1 shift from last week.'
    assert_includes flash[:notice], 'Skipped 1'
    copy = @other.scheduled_shifts.where('starts_at >= ?', next_monday.in_time_zone).sole
    assert_equal next_monday.in_time_zone + 9.hours, copy.starts_at
    assert_equal 'PRIVATEOTHER', copy.role_label
    assert ActivityLog.exists?(action: 'scheduled_week_copied')

    assert_no_difference 'People::ScheduledShift.count' do
      post copy_last_week_people_scheduled_shifts_path(week: next_monday.iso8601)
    end
    assert_includes flash[:notice], 'Skipped 2'
  end

  test 'copy last week keeps wall-clock times across the end of daylight saving' do
    sign_in(users(:regular_user), 'password')
    friday = Date.new(2026, 10, 30)
    @worker.scheduled_shifts.create!(starts_at: friday.in_time_zone + 9.hours, ends_at: friday.in_time_zone + 17.hours)
    post copy_last_week_people_scheduled_shifts_path(week: '2026-11-02')
    copy = @worker.scheduled_shifts.where('starts_at >= ?', Date.new(2026, 11, 2).in_time_zone).sole
    assert_equal '2026-11-06 09:00', copy.starts_at.in_time_zone.strftime('%Y-%m-%d %H:%M')
    assert_equal '2026-11-06 17:00', copy.ends_at.in_time_zone.strftime('%Y-%m-%d %H:%M')
    assert_equal 8.0, copy.hours
  end

  test 'copy last week needs schedule editing' do
    sign_in(@user, 'password123')
    assert_no_difference 'People::ScheduledShift.count' do
      post copy_last_week_people_scheduled_shifts_path(week: (@monday + 7).iso8601)
    end
    delete logout_path
    reader = User.create!(tenant: @tenant, email: 'schedule-reader@example.com', password: 'password123', role: 'shift_leader')
    reader.user_permissions.create!(tenant_id: @tenant.id, permission: 'hr.read', enabled: true)
    sign_in(reader, 'password123')
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_response :success
    assert_select 'form[action^=?]', copy_last_week_people_scheduled_shifts_path, count: 0
    assert_no_difference 'People::ScheduledShift.count' do
      post copy_last_week_people_scheduled_shifts_path(week: (@monday + 7).iso8601)
    end
  end

  test 'shifts on approved leave are flagged but still saved' do
    sign_in(users(:regular_user), 'password')
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-leave-warning]', count: 0
    @worker.leave_requests.create!(leave_type: 'unpaid', starts_on: @monday, ends_on: @monday)
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-on-leave]', count: 0

    @worker.leave_requests.create!(leave_type: 'unpaid', starts_on: @monday, ends_on: @monday).approve!
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-leave-warning]', text: /1 shift this week falls on approved leave/
    assert_select "[data-on-leave='#{@mine.id}']", 'On approved leave'

    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{@monday}T18:00", ends_at: "#{@monday}T20:00" } }
    end
    assert_includes flash[:notice], 'Alex Planned has approved leave on this day'
    post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{@monday + 2}T10:00", ends_at: "#{@monday + 2}T12:00" } }
    assert_equal 'Shift scheduled.', flash[:notice]
  end

  test 'over 40 planned hours is flagged against the Thursday-Wednesday pay week but saving still works' do
    sign_in(users(:regular_user), 'password')
    @mine.destroy!
    thursday = @monday + 3
    4.times { |offset| @worker.scheduled_shifts.create!(starts_at: (thursday + offset).in_time_zone + 9.hours, ends_at: (thursday + offset).in_time_zone + 18.hours) }
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-hours-warning]', count: 0

    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{@monday + 7}T09:00", ends_at: "#{@monday + 7}T18:00" } }
    end
    assert_includes flash[:notice], 'Shift scheduled.'
    assert_includes flash[:notice], 'Alex Planned is planned for 45 hours in the pay week Thu Oct 22 – Wed Oct 28, over 40.'

    # The Monday-Sunday grid shows 36 hours, but the pay week reaching into next Monday is over 40.
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-hours-warning]', text: /Alex Planned: 45 hours, Thu Oct 22 – Wed Oct 28/
    assert_select '[data-hours-warning]', text: /planned hours, not pay/
    assert_select "[data-over-hours='#{@worker.id}']", /Over 40 in pay week/
    refute_includes css_select('[data-hours-warning]').text, 'Someone Else'
    get people_scheduled_shifts_path(week: (@monday - 7).iso8601)
    assert_select '[data-hours-warning]', count: 0
  end

  test 'a short rest between shifts is flagged across the week boundary but saving still works' do
    sign_in(users(:regular_user), 'password')
    sunday = @monday + 6
    late = @worker.scheduled_shifts.create!(starts_at: sunday.in_time_zone + 14.hours, ends_at: sunday.in_time_zone + 23.hours)

    assert_difference 'People::ScheduledShift.count', 1 do
      post people_scheduled_shifts_path, params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{sunday + 1}T06:00", ends_at: "#{sunday + 1}T12:00" } }
    end
    early = People::ScheduledShift.order(:id).last
    assert_includes flash[:notice], 'Only 7 hours between this shift and another for Alex Planned (less than 10).'

    get people_scheduled_shifts_path(week: (@monday + 7).iso8601)
    assert_select '[data-rest-warning]', text: /1 shift this week starts less than 10 hours after/
    assert_select "[data-short-rest='#{early.id}']", 'Short rest: 7 h since last shift'
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-rest-warning]', count: 0

    # Editing the earlier shift warns about the gap to the next one; exactly 10 hours is fine.
    patch people_scheduled_shift_path(late), params: { scheduled_shift: { starts_at: "#{sunday}T12:00", ends_at: "#{sunday}T22:00" } }
    assert_equal late.reload.ends_at, sunday.in_time_zone + 22.hours
    assert_includes flash[:notice], 'Only 8 hours between this shift'
    patch people_scheduled_shift_path(late), params: { scheduled_shift: { starts_at: "#{sunday}T10:00", ends_at: "#{sunday}T20:00" } }
    assert_equal 'Shift updated.', flash[:notice]
  end
end
