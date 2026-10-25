# frozen_string_literal: true

require 'test_helper'

# The per-employee training flag (#465): set on the staff form by people who can edit staff, shown on the staff page,
# and read by the incentives model.
class EmployeeTrainingFlagTest < ActionDispatch::IntegrationTest
  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @employee = People::Employee.create!(first_name: 'Trainee', last_name: 'Person', employment_type: 'part_time')
  end

  teardown { Current.reset }

  def training_params(starts_on: '2026-10-01', ends_on: '2026-12-31')
    { employee: { first_name: 'Trainee', last_name: 'Person', in_training: '1', training_starts_on: starts_on, training_ends_on: ends_on } }
  end

  test 'staff editors set the training flag and dates, and the staff page shows them' do
    post login_path, params: { email: @admin.email, password: 'password' }
    get edit_people_employee_path(@employee)
    assert_response :success
    assert_select 'input[type=checkbox][name=?]', 'employee[in_training]'
    assert_select 'input[type=date][name=?]', 'employee[training_starts_on]'

    patch people_employee_path(@employee), params: training_params
    assert_redirected_to people_employee_path(@employee)
    @employee.reload
    assert @employee.in_training?
    assert_equal Date.new(2026, 10, 1), @employee.training_starts_on
    assert_equal Date.new(2026, 12, 31), @employee.training_ends_on

    get people_employee_path(@employee)
    assert_select 'dt', 'Training'
    assert_select 'dd', /Oct 1, 2026 – Dec 31, 2026/
  end

  test 'an end before the start is refused with a field error' do
    post login_path, params: { email: @admin.email, password: 'password' }
    patch people_employee_path(@employee), params: training_params(starts_on: '2026-10-10', ends_on: '2026-10-01')
    assert_response :unprocessable_content
    assert_select 'input[name=?][aria-invalid=true]', 'employee[training_ends_on]'
    assert_not @employee.reload.in_training?
  end

  test 'staff who can read but not edit staff cannot set the flag' do
    manager = User.create!(tenant: Current.tenant, email: 'training-manager@example.com', role: 'manager', password: 'password123')
    post login_path, params: { email: manager.email, password: 'password123' }
    patch people_employee_path(@employee), params: training_params
    assert_includes [302, 303, 403, 404], response.status
    assert_not @employee.reload.in_training?
  end

  test 'the incentives model ticks staff in training from their records' do
    @employee.update!(user: @admin, in_training: true, training_starts_on: 30.days.ago.to_date)
    ClockShift.create!(user: @admin, employee: @employee, employee_key: @employee.id.to_s, employee_name: @employee.name,
      employment_type: @employee.employment_type, started_at: 3.days.ago.change(hour: 9),
      ended_at: 3.days.ago.change(hour: 12), request_token: SecureRandom.uuid)
    post login_path, params: { email: @admin.email, password: 'password' }
    get people_incentives_path(period: 'custom', from: 7.days.ago.to_date, to: Date.current)
    assert_response :success
    assert_select 'select[name=training_from] option[selected][value=records]'
    assert_select "input[name='trainees[]'][value=?][checked]", @employee.id.to_s
  end
end
