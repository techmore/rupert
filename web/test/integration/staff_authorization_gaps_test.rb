# frozen_string_literal: true

require 'test_helper'
require_relative '../support/compliance_fixtures'

# Staff roles are refused where their permissions or store limits say so, by direct request and
# not only by a hidden link, and the owner (admin) is still allowed.
class StaffAuthorizationGapsTest < ActionDispatch::IntegrationTest
  include ComplianceFixtures

  DENIED = "You don't have permission to do that."

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @owner = users(:regular_user)
  end

  teardown { Current.reset }

  # ---- Bulk material use: new and create need inventory.write, like preview ----

  test 'a read-only role cannot open or post the material use form, an inventory writer can' do
    %w[reader reporting cashier].each do |role|
      user = sign_in_as(role)
      assert_not user.can?('inventory.write')
      get new_bulk_consumption_path
      assert_denied "#{role} opened the material use form"
      assert_no_difference('BulkConsumption.count') do
        post bulk_consumptions_path, params: { bulk_consumption: { preview_token: 'not-a-token', confirmed: '1' } }
      end
      assert_denied "#{role} reached the material use create action"
      get bulk_consumptions_path
      assert_response :success, "#{role} still reads the list with inventory.read"
    end

    [sign_in_as('inventory_employee'), sign_in_as(@owner)].each do |user|
      assert user.can?('inventory.write')
      post bulk_consumptions_path, params: { bulk_consumption: { preview_token: 'not-a-token', confirmed: '1' } }
      assert_redirected_to bulk_consumptions_path
      assert_match(/Review and confirm/, flash[:alert], "#{user.role} passes the permission check and reaches the token check")
    end
  end

  # ---- A manager limited to some stores ----

  test 'a store-limited manager cannot decide time off for another store, the owner can' do
    manager, _mine, other = store_limited_manager
    leave = other.leave_requests.create!(leave_type: People::LeaveRequest::LEAVE_TYPES.first, starts_on: Date.current + 30, ends_on: Date.current + 31)
    sign_in_as(manager)

    %i[approve deny cancel].each do |event|
      post public_send(:"#{event}_people_leave_request_path", leave)
      assert_redirected_to people_leave_requests_path
      assert_match(/store you do not manage/, flash[:alert])
      assert_equal 'requested', leave.reload.status, "#{event} changed another store's request"
    end
    assert_raises(Pundit::NotAuthorizedError) do
      Current.set(user: manager, tenant: @tenant) { LeaveRequestWorkflow.change(leave, :approve) }
    end

    sign_in_as(@owner)
    post approve_people_leave_request_path(leave)
    assert_equal 'approved', leave.reload.status
  end

  test 'a store-limited manager still decides time off for their own store' do
    manager, mine, = store_limited_manager
    leave = mine.leave_requests.create!(leave_type: People::LeaveRequest::LEAVE_TYPES.first, starts_on: Date.current + 30, ends_on: Date.current + 31)
    sign_in_as(manager)
    post approve_people_leave_request_path(leave)
    assert_equal 'approved', leave.reload.status
  end

  test 'a store-limited manager cannot read, edit or delete another store’s timesheet, the owner can' do
    manager, mine, other = store_limited_manager
    theirs = other.timesheets.create!(period_start: '2026-07-27', period_end: '2026-08-02', notes: 'original')
    ours = mine.timesheets.create!(period_start: '2026-07-27', period_end: '2026-08-02', notes: 'original')
    sign_in_as(manager)

    get people_timesheet_path(theirs)
    assert_denied 'read another store’s timesheet'
    patch people_timesheet_path(theirs), params: { timesheet: { notes: 'changed' } }
    assert_denied 'edited another store’s timesheet'
    post add_entry_people_timesheet_path(theirs), params: { timesheet_entry: { worked_on: '2026-07-27', hours: 8, work_type: 'regular' } }
    assert_denied 'added hours to another store’s timesheet'
    delete people_timesheet_path(theirs)
    assert_denied 'deleted another store’s timesheet'
    theirs.reload
    assert_equal 'original', theirs.notes
    assert_equal 0, theirs.entries.count

    get people_timesheet_path(ours)
    assert_response :success
    patch people_timesheet_path(ours), params: { timesheet: { notes: 'changed' } }
    assert_equal 'changed', ours.reload.notes

    sign_in_as(@owner)
    get people_timesheet_path(theirs)
    assert_response :success
    patch people_timesheet_path(theirs), params: { timesheet: { notes: 'owner note' } }
    assert_equal 'owner note', theirs.reload.notes
  end

  test 'a store-limited manager cannot plan, move or remove another store’s shifts, the owner can' do
    manager, mine, other = store_limited_manager
    monday = Date.current.beginning_of_week + 7
    times = { starts_at: (monday.in_time_zone + 9.hours).iso8601, ends_at: (monday.in_time_zone + 12.hours).iso8601 }
    theirs = other.scheduled_shifts.create!(location_id: @store_b.id, starts_at: monday.in_time_zone + 13.hours, ends_at: monday.in_time_zone + 17.hours)
    sign_in_as(manager)

    assert_no_difference('People::ScheduledShift.count') do
      post people_scheduled_shifts_path, params: { scheduled_shift: times.merge(employee_id: other.id, location_id: @store_b.id) }
      assert_denied 'planned a shift at another store'
      post people_scheduled_shifts_path, params: { scheduled_shift: times.merge(employee_id: other.id, location_id: @store_a.id) }
      assert_denied 'planned another store’s person'
      delete people_scheduled_shift_path(theirs)
      assert_denied 'removed another store’s shift'
    end
    patch people_scheduled_shift_path(theirs), params: { scheduled_shift: { notes: 'moved' } }
    assert_denied 'changed another store’s shift'
    assert_nil theirs.reload.notes

    assert_difference('People::ScheduledShift.count', 1) do
      post people_scheduled_shifts_path, params: { scheduled_shift: times.merge(employee_id: mine.id, location_id: @store_a.id) }
    end
    own = mine.scheduled_shifts.sole
    patch people_scheduled_shift_path(own), params: { scheduled_shift: { location_id: @store_b.id } }
    assert_denied 'moved a shift to a store outside their limit'
    assert_equal @store_a.id, own.reload.location_id

    sign_in_as(@owner)
    assert_difference('People::ScheduledShift.count', 1) do
      post people_scheduled_shifts_path, params: { scheduled_shift: times.merge(employee_id: other.id, location_id: @store_b.id) }
    end
    patch people_scheduled_shift_path(theirs), params: { scheduled_shift: { notes: 'owner note' } }
    assert_equal 'owner note', theirs.reload.notes
  end

  # ---- Pay rates on the schedule need payroll.read, as they do on the staff profile ----

  test 'the schedule shows hourly rates only to people who may read payroll' do
    worker = People::Employee.create!(first_name: 'Paid', last_name: 'Person')
    worker.pay_rates.create!(pay_type: 'hourly', pay_frequency: People::PayRate::PAY_FREQUENCIES.first, hourly_rate_cents: 2357, effective_on: 1.year.ago.to_date)
    monday = Date.current.beginning_of_week
    worker.scheduled_shifts.create!(starts_at: monday.in_time_zone + 9.hours, ends_at: monday.in_time_zone + 17.hours)

    manager = sign_in_as('manager')
    assert_not manager.can?('payroll.read')
    get people_scheduled_shifts_path(week: monday.iso8601)
    assert_response :success
    assert_includes response.body, 'Paid Person'
    assert_not_includes response.body, '$23.57/h'

    sign_in_as(@owner)
    get people_scheduled_shifts_path(week: monday.iso8601)
    assert_includes response.body, '$23.57/h'
  end

  # ---- Event register: only the event's staff and managers see its items and approvers ----

  test 'someone off the event staff list sees no items, prices or approvers; staff and the owner do' do
    Finance::ChartOfAccounts.seed!
    location = compliance_store(name: 'Event store')
    manager = manager_with_pin
    item = approve!(location, '11', name: 'Hemp Extract 1000mg', category: card_category, approved_price_cents: 4000)
    seller = User.create!(tenant: @tenant, email: 'event-seller@example.com', password: 'password123', role: 'employee')
    outsider = User.create!(tenant: @tenant, email: 'event-outsider@example.com', password: 'password123', role: 'employee')
    event = PosEvent.create!(name: 'Fair', location: location, starts_on: Date.current, ends_on: Date.current, tax_rate_bps: 600,
      opening_float_cents: 0, staff_user_ids_json: [seller.id], status: 'open', opened_at: 1.hour.ago)
    event.pos_event_items.create!(compliance_catalog_item: item, name: item.receipt_label, price_cents: 4000, card_eligible: true, loaded_quantity: 5)

    sign_in_as(outsider)
    get pos_event_register_path(event, format: :json)
    assert_response :success
    assert_equal false, response.parsed_body['seller']
    assert_empty response.parsed_body['items']
    assert_empty response.parsed_body['approvers']
    get pos_event_register_path(event)
    assert_response :success
    assert_includes response.body, 'not on this event’s staff list'
    assert_includes response.body, 'Ask the event manager to add you.'
    assert_not_includes response.body, item.receipt_label

    sign_in_as(seller)
    get pos_event_register_path(event, format: :json)
    assert_equal true, response.parsed_body['seller']
    assert_equal 1, response.parsed_body['items'].size
    assert_includes response.parsed_body['approvers'].pluck('id'), manager.id

    sign_in_as(@owner)
    get pos_event_register_path(event, format: :json)
    assert_equal 1, response.parsed_body['items'].size
    assert_includes response.parsed_body['approvers'].pluck('id'), manager.id
  end

  private

  def sign_in_as(role_or_user)
    user = role_or_user.is_a?(User) ? role_or_user : User.find_or_create_by!(tenant: @tenant, email: "#{role_or_user}-gaps@example.com") do |new_user|
      new_user.password = 'password123'
      new_user.role = role_or_user
    end
    delete logout_path
    sign_in user
    Current.tenant = @tenant
    user
  end

  def assert_denied(message)
    assert((response.redirect? && flash[:alert].to_s == DENIED) || response.forbidden?, "expected a refusal: #{message} (#{response.status})")
  end

  # A manager limited to Store A, one worker there and one worker at Store B only.
  def store_limited_manager
    @store_a = Location.create!(name: 'Store A', source: 'rupert', externalId: 'gaps-a', active: true)
    @store_b = Location.create!(name: 'Store B', source: 'rupert', externalId: 'gaps-b', active: true)
    manager = User.create!(tenant: @tenant, email: 'store-a-manager@example.com', password: 'password123', role: 'manager', location_ids: [@store_a.id])
    mine = People::Employee.create!(first_name: 'Ada', last_name: 'Ownstore', location_ids: [@store_a.id])
    other = People::Employee.create!(first_name: 'Otto', last_name: 'Otherstore', location_ids: [@store_b.id])
    [manager, mine, other]
  end
end
