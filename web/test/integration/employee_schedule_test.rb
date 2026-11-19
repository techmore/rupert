# frozen_string_literal: true

require 'test_helper'

# The worker's schedule: posted shifts only, open shifts at their stores, the team view, the
# calendar feed, self-service availability, and the staff-app JSON endpoints.
class EmployeeScheduleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'sched-worker@example.com', password: 'password123', role: 'employee', name: 'Alex')
    @worker = People::Employee.create!(first_name: 'Alex', last_name: 'Planned', user: @user)
    @other = People::Employee.create!(first_name: 'Sam', last_name: 'Other')
    @monday = (Date.current + 7).beginning_of_week
    @mine = @worker.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 9.hours, ends_at: @monday.in_time_zone + 17.hours, published_at: Time.current, break_minutes: 30)
    @draft = @worker.scheduled_shifts.create!(starts_at: (@monday + 1).in_time_zone + 9.hours, ends_at: (@monday + 1).in_time_zone + 17.hours)
    @team = @other.scheduled_shifts.create!(starts_at: @monday.in_time_zone + 12.hours, ends_at: @monday.in_time_zone + 18.hours, published_at: Time.current)
    @open = People::ScheduledShift.create!(starts_at: (@monday + 2).in_time_zone + 9.hours, ends_at: (@monday + 2).in_time_zone + 13.hours, published_at: Time.current)
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'shows posted shifts, open shifts and team on request, never drafts' do
    get employee_schedule_path(week: @monday.iso8601)
    assert_response :success
    assert_select "[data-my-shift='#{@mine.id}']", /7\.5 h/
    assert_select "[data-my-shift='#{@draft.id}']", count: 0
    assert_select "[data-open-shift='#{@open.id}']"
    assert_select "[data-team-shift='#{@team.id}']", count: 0
    get employee_schedule_path(week: @monday.iso8601, team: 1)
    assert_select "[data-team-shift='#{@team.id}']", /Sam · 12:00 PM – 6:00 PM/
  end

  test 'calendar feed needs the signed token and lists posted shifts only' do
    get employee_schedule_path(format: :ics, token: 'bad')
    assert_response :unauthorized
    get employee_schedule_path(format: :ics, token: EmployeeScheduleFeed.token(@worker))
    assert_response :success
    assert_includes response.body, "UID:rupert-shift-#{@tenant.id}-#{@mine.id}"
    refute_includes response.body, "UID:rupert-shift-#{@tenant.id}-#{@draft.id}"
    refute_includes response.body, "UID:rupert-shift-#{@tenant.id}-#{@team.id}"
  end

  test 'a worker edits their own availability' do
    post employee_availability_index_path, params: { employee_availability: { weekday: 6, kind: 'unavailable', start_time: '08:00', end_time: '12:00' } }
    assert_redirected_to employee_availability_index_path
    block = @worker.availabilities.sole
    assert_equal [480, 720], [block.start_minute, block.end_minute]
    get employee_availability_index_path
    assert_includes response.body, 'Saturday'
    delete employee_availability_path(block)
    assert_empty @worker.availabilities.reload
  end

  test 'staff app endpoints: schedule, leave requests and trades' do
    session, token = EmployeeAppSession.issue!(user: @user, device_name: 'Test phone')
    assert session
    EmployeeAppSession.stubs(:enabled?).returns(true)
    headers = { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
    get '/api/v1/employee/schedule', params: { week: @monday.iso8601 }, headers: headers
    assert_response :success
    body = response.parsed_body
    assert_equal [@mine.id], body['data'].map { |s| s['id'] }
    assert_equal [@open.id], body['open_shifts'].map { |s| s['id'] }

    post '/api/v1/employee/leave_requests', params: { leave_request: { leave_type: 'sick', starts_on: @monday, ends_on: @monday, request_key: 'k1' } }.to_json, headers: headers
    assert_response :created
    post '/api/v1/employee/leave_requests', params: { leave_request: { leave_type: 'sick', starts_on: @monday, ends_on: @monday, request_key: 'k1' } }.to_json, headers: headers
    assert_response :success
    assert_equal 1, @worker.leave_requests.count
    get '/api/v1/employee/leave_requests', headers: headers
    assert_equal 'sick', response.parsed_body['data'].first['leave_type']
    assert_equal 3, response.parsed_body['balances'].size

    post '/api/v1/employee/trades', params: { kind: 'pickup', shift_id: @open.id }.to_json, headers: headers
    assert_response :created
    trade = People::ShiftTrade.sole
    assert_equal 'accepted', trade.status
    post "/api/v1/employee/trades/#{trade.id}/cancel", headers: headers
    assert_equal 'cancelled', trade.reload.status
  end
end
