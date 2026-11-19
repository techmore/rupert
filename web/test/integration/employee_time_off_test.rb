# frozen_string_literal: true

require 'test_helper'

# The redesigned time-off request: type chips, default hours from posted shifts, balances,
# blackout and notice callouts, idempotent sends, manager notification, Spanish.
class EmployeeTimeOffTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'timeoff-manager@example.com', password: 'password123', role: 'manager')
    @user = User.create!(tenant: @tenant, email: 'timeoff-worker@example.com', password: 'password123', role: 'employee', name: 'Alex')
    @worker = People::Employee.create!(first_name: 'Alex', last_name: 'Planned', user: @user)
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'request defaults hours from posted shifts, shows balances and blackouts, and tells managers once' do
    day = Date.current + 14
    @worker.scheduled_shifts.create!(starts_at: day.in_time_zone + 9.hours, ends_at: day.in_time_zone + 15.hours, break_minutes: 30, published_at: Time.current)
    People::BlackoutDate.create!(starts_on: day + 1, ends_on: day + 2, reason: 'Holiday rush')
    get employee_time_off_path
    assert_response :success
    assert_select '.type-chip', 4
    assert_select '[data-balance="vacation"]', '80 h'
    assert_includes response.body, 'Holiday rush'
    assert_includes response.body, 'at least 7 days ahead'

    key = SecureRandom.uuid
    assert_difference -> { @worker.leave_requests.count }, 1 do
      2.times { post employee_time_off_path, params: { leave_request: { leave_type: 'vacation', starts_on: day, ends_on: day, request_key: key } } }
    end
    request = @worker.leave_requests.sole
    assert_equal 5.5, request.hours.to_f, 'posted shift minus its unpaid break'
    assert_equal key, request.request_key
    assert Notification.where(user_id: @manager.id, kind: 'approvals').sole.title.include?('Alex Planned asks')
    get employee_time_off_path
    assert_select "[data-leave-request='#{request.id}'] .pill-clay", 'Waiting'
    post cancel_employee_time_off_path(request)
    assert request.reload.cancelled?
  end

  test 'a worker whose language is Spanish sees the time-off page in Spanish' do
    @worker.update!(locale: 'es')
    get employee_time_off_path
    assert_response :success
    assert_select 'h1', 'Tiempo libre'
    assert_select '.type-chip', text: 'Vacaciones'
    assert_select 'input[type=submit][value="Pedir tiempo libre"]'
  end
end
