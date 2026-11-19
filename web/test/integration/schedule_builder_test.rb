# frozen_string_literal: true

require 'test_helper'

# The drag-and-drop schedule builder: JSON add/move/resize, open shifts, warnings, labour line,
# templates, posting a week and telling staff.
class ScheduleBuilderTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'builder-manager@example.com', password: 'password123', role: 'manager', name: 'Mo Manager')
    @user = User.create!(tenant: @tenant, email: 'builder-worker@example.com', password: 'password123', role: 'employee', name: 'Alex Planned')
    @worker = People::Employee.create!(first_name: 'Alex', last_name: 'Planned', user: @user)
    People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2000, pay_frequency: 'weekly', effective_on: Date.new(2025, 1, 1))
    @other = People::Employee.create!(first_name: 'Sam', last_name: 'Other')
    @monday = Date.new(2026, 11, 16)
    post login_path, params: { email: @manager.email, password: 'password123' }
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def json_headers
    { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
  end

  test 'builder adds, moves, resizes and reassigns a shift over JSON and re-renders the chip' do
    post people_scheduled_shifts_path(format: :json), params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{@monday}T09:00:00-05:00", ends_at: "#{@monday}T17:00:00-05:00", role_label: 'Counter', break_minutes: 30 } }.to_json, headers: json_headers
    assert_response :created
    body = response.parsed_body
    shift = People::ScheduledShift.find(body['id'])
    assert_equal @worker.id, body['employee_id']
    assert_includes body['html'], 'shift-chip-draft'
    assert_includes body['html'], 'Draft'
    assert_equal 30, shift.break_minutes
    assert_in_delta 7.5 * 2000, body['labor']['total']['cost_cents'], 1

    # Move to Tuesday for Sam (drag and drop).
    patch people_scheduled_shift_path(shift, format: :json), params: { scheduled_shift: { employee_id: @other.id, starts_at: "#{@monday + 1}T09:00:00-05:00", ends_at: "#{@monday + 1}T17:00:00-05:00" } }.to_json, headers: json_headers
    assert_response :success
    assert_equal @other.id, shift.reload.employee_id
    assert_equal (@monday + 1), shift.starts_at.to_date

    # Resize the end (drag the lower edge).
    patch people_scheduled_shift_path(shift, format: :json), params: { scheduled_shift: { ends_at: "#{@monday + 1}T18:15:00-05:00" } }.to_json, headers: json_headers
    assert_response :success
    assert_equal 15, shift.reload.ends_at.min

    # Make it an open shift.
    patch people_scheduled_shift_path(shift, format: :json), params: { scheduled_shift: { employee_id: 'open' } }.to_json, headers: json_headers
    assert_response :success
    assert_nil shift.reload.employee_id
    assert_includes response.parsed_body['html'], 'shift-chip-open'

    # An overlap is refused with the reason.
    @worker.scheduled_shifts.create!(starts_at: (@monday + 2).in_time_zone + 9.hours, ends_at: (@monday + 2).in_time_zone + 17.hours)
    post people_scheduled_shifts_path(format: :json), params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{@monday + 2}T12:00:00-05:00", ends_at: "#{@monday + 2}T14:00:00-05:00" } }.to_json, headers: json_headers
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'overlaps'
  end

  test 'warnings appear as chips: availability, minor rules, blackout, time off' do
    @worker.update!(date_of_birth: 16.years.ago.to_date)
    @worker.availabilities.create!(weekday: @monday.wday, start_minute: 0, end_minute: 12 * 60, kind: 'unavailable')
    People::BlackoutDate.create!(starts_on: @monday, ends_on: @monday, reason: 'Inventory')
    shift = @worker.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 6.hours, ends_at: @monday.in_time_zone + 15.hours)
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_response :success
    assert_select "[data-shift-id='#{shift.id}'] [data-warning='availability']", 'Unavailable'
    assert_select "[data-shift-id='#{shift.id}'] [data-warning='minor_hours']"
    assert_select "[data-shift-id='#{shift.id}'] [data-warning='minor_daily']"
    assert_select "[data-shift-id='#{shift.id}'] [data-warning='blackout']", 'Blackout'
    assert_select '[data-labor="hours"]', /9 h/
    assert_select '[data-labor="cost"]', '$180.00'
  end

  test 'posting a week stamps drafts, records the publication, tells workers, and hides drafts from staff until then' do
    draft = @worker.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours)
    delete logout_path
    post login_path, params: { email: @user.email, password: 'password123' }
    get employee_schedule_path(week: @monday.iso8601)
    assert_select "[data-my-shift='#{draft.id}']", count: 0
    assert_includes response.body, 'No shift planned'
    delete logout_path
    post login_path, params: { email: @manager.email, password: 'password123' }

    travel_to(@monday - 3) do
      assert_difference -> { People::SchedulePublication.count }, 1 do
        post publish_people_scheduled_shifts_path(week: @monday.iso8601)
      end
    end
    assert_redirected_to people_scheduled_shifts_path(week: @monday.iso8601)
    assert_includes flash[:notice], 'Posted 1 shift to 1 person'
    assert_includes flash[:notice], 'only 3 days of notice'
    assert draft.reload.published?
    notification = Notification.where(user_id: @user.id, kind: 'schedule_posted').sole
    assert_includes notification.title, 'week of Nov 16'

    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_select '[data-posted]', /Posted/
    assert_select "[data-shift-id='#{draft.id}'] .shift-chip-pill", text: 'Draft', count: 0

    # Changing a posted shift tells the worker; cancelling keeps the row.
    patch people_scheduled_shift_path(draft), params: { scheduled_shift: { ends_at: "#{@monday}T18:00" } }
    assert Notification.where(user_id: @user.id, kind: 'schedule_changed').exists?
    assert_no_difference -> { People::ScheduledShift.unscoped.count } do
      delete people_scheduled_shift_path(draft)
    end
    assert draft.reload.cancelled?
    assert_includes flash[:notice], 'cancelled'

    delete logout_path
    post login_path, params: { email: @user.email, password: 'password123' }
    get employee_schedule_path(week: @monday.iso8601)
    assert_select "[data-my-shift='#{draft.id}']", count: 0
  end

  test 'templates capture a week and apply it to another as drafts' do
    @worker.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours, role_label: 'Counter')
    People::ScheduledShift.create!(starts_at: (@monday + 1).in_time_zone + 10.hours, ends_at: (@monday + 1).in_time_zone + 14.hours)
    get new_people_schedule_template_path(week: @monday.iso8601)
    assert_response :success
    assert_difference -> { People::ScheduleTemplate.count }, 1 do
      post people_schedule_templates_path(week: @monday.iso8601), params: { schedule_template: { name: 'Standard week' } }
    end
    template = People::ScheduleTemplate.sole
    assert_equal 2, template.shifts.count
    assert_difference -> { People::ScheduledShift.count }, 2 do
      post apply_people_schedule_template_path(template, week: (@monday + 14).iso8601)
    end
    assert_includes flash[:notice], 'Added 2 draft shifts'
    copied = People::ScheduledShift.between(@monday + 14, @monday + 20).to_a
    assert_equal [nil, @worker.id].sort_by(&:to_i), copied.map(&:employee_id).sort_by(&:to_i)
    assert copied.all? { |s| !s.published? }
    get people_schedule_templates_path
    assert_includes response.body, 'Standard week'
  end

  test 'blackout dates and availability pages are managed by leave and schedule writers' do
    post people_blackout_dates_path, params: { blackout_date: { starts_on: @monday, ends_on: @monday + 2, reason: 'Holiday rush' } }
    assert_redirected_to people_blackout_dates_path
    get people_blackout_dates_path
    assert_includes response.body, 'Holiday rush'
    post people_availabilities_path(employee_id: @worker.id), params: { employee_availability: { weekday: 0, kind: 'unavailable', all_day: '1' } }
    assert_redirected_to people_availabilities_path(employee_id: @worker.id)
    assert_equal 1440, @worker.availabilities.sole.end_minute
    get people_availabilities_path(employee_id: @worker.id)
    assert_includes response.body, 'All day'
  end

  test 'shift leaders without schedule.write cannot change the grid' do
    leader = User.create!(tenant: @tenant, email: 'builder-leader@example.com', password: 'password123', role: 'shift_leader')
    leader.user_permissions.create!(tenant_id: @tenant.id, permission: 'hr.read', enabled: true)
    delete logout_path
    post login_path, params: { email: leader.email, password: 'password123' }
    get people_scheduled_shifts_path(week: @monday.iso8601)
    assert_response :success
    assert_select '.shift-chip[draggable]', count: 0
    post people_scheduled_shifts_path(format: :json), params: { scheduled_shift: { employee_id: @worker.id, starts_at: "#{@monday}T09:00", ends_at: "#{@monday}T17:00" } }.to_json, headers: json_headers
    assert_response :redirect
    assert_equal 0, People::ScheduledShift.count
  end
end
