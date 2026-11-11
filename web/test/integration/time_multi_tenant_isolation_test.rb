# frozen_string_literal: true

require 'test_helper'

# Two workspaces with the same-looking time records: the same staff name, employee number and
# clock PIN, a closed punch, a pending fix, a timesheet, time off and a posted shift in each.
# Nothing one workspace does (web, staff API, PIN clock, exports, jobs, push) may read or change
# the other's, and each keeps its own clock and its own settings.
class TimeMultiTenantIsolationTest < ActionDispatch::IntegrationTest
  Shop = Struct.new(:tenant, :admin, :user, :worker, :shift, :correction, :sheet, :leave, :planned, keyword_init: true)

  setup do
    @a = build_shop('North Shop', 'north', hours: 3)
    @b = build_shop('South Shop', 'south', hours: 5, time_zone: 'America/Los_Angeles')
    Current.reset
  end

  teardown { Current.reset }

  def build_shop(name, slug, hours:, time_zone: nil)
    tenant = Tenant.create!(name: name, subdomain: "#{slug}-#{SecureRandom.hex(3)}", time_zone: time_zone)
    Current.tenant = tenant
    admin = User.create!(tenant: tenant, name: "#{name} Admin", email: "admin-#{slug}@example.com", role: 'admin', password: 'password123')
    user = User.create!(tenant: tenant, name: 'Sam Rivers', email: "sam-#{slug}@example.com", role: 'employee', password: 'password123')
    worker = People::Employee.create!(user: user, first_name: 'Sam', last_name: 'Rivers', employment_type: 'part_time', employee_number: 'E1', email: user.email)
    worker.set_pin!('2580')
    started = Time.utc(2026, 7, 6, 14, 0)
    shift = ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s, employee_name: worker.name, employment_type: worker.employment_type,
      started_at: started, ended_at: started + hours.hours, request_token: SecureRandom.hex(12))
    correction = shift.corrections.create!(requested_by_id: user.id, original_started_at: shift.started_at, original_ended_at: shift.ended_at,
      proposed_started_at: shift.started_at, proposed_ended_at: shift.ended_at + 30.minutes, reason: 'Stayed late')
    sheet = People::Timesheet.create!(employee: worker, period_start: '2026-07-06', period_end: '2026-07-12')
    sheet.entries.create!(worked_on: '2026-07-07', hours: hours, work_type: 'regular', notes: "#{slug} hours")
    leave = People::LeaveRequest.create!(employee: worker, leave_type: 'unpaid', starts_on: Date.current + 30, ends_on: Date.current + 30, reason: "#{slug} trip")
    planned = People::ScheduledShift.create!(employee: worker, starts_at: 3.days.from_now.change(hour: 15), ends_at: 3.days.from_now.change(hour: 20), published_at: Time.current)
    Shop.new(tenant: tenant, admin: admin, user: user, worker: worker, shift: shift, correction: correction, sheet: sheet, leave: leave, planned: planned)
  end

  def login(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
    assert_response :redirect
  end

  def app_token(user)
    post '/api/v1/employee/session', params: { email: user.email, password: 'password123', device_name: 'Test phone' }, as: :json
    assert_response :created
    { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
  end

  def within(shop, &) = Current.with_tenant(shop.tenant, &)

  test 'staff pages never open another workspace’s records' do
    login(@a.user)
    get people_timesheet_path(@a.sheet)
    assert_response :success
    get people_timesheet_path(@b.sheet)
    assert_response :not_found
    post submit_people_timesheet_path(@b.sheet)
    assert_response :not_found
    post import_shifts_people_timesheet_path(@b.sheet)
    assert_response :not_found
    post request_correction_time_clock_path(@b.shift), params: { clock_correction: { proposed_started_at: '2026-07-06T10:00', proposed_ended_at: '2026-07-06T12:00', reason: 'Not mine' } }
    assert_response :not_found
    get fix_clock_out_time_clock_path(@b.shift)
    assert_response :not_found
    post cancel_employee_time_off_path(@b.leave)
    assert_response :not_found
    post employee_trades_path, params: { kind: 'give', shift_id: @b.planned.id }
    assert_response :not_found
    assert_equal 1, ClockCorrection.unscoped.where(clock_shift_id: @b.shift.id).count
    assert_equal 'draft', People::Timesheet.unscoped.find(@b.sheet.id).status
    assert_equal 'requested', People::LeaveRequest.unscoped.find(@b.leave.id).status
    assert_equal 0, People::ShiftTrade.unscoped.where(tenant_id: @b.tenant.id).count

    get people_timesheets_path(view: 'list')
    assert_response :success
    assert_select 'a[href=?]', people_timesheet_path(@b.sheet), count: 0
  end

  test 'an administrator reviews, exports and schedules only inside their own workspace' do
    login(@a.admin)
    post approve_correction_time_clock_path(@b.correction)
    assert_response :not_found
    post approve_people_timesheet_path(@b.sheet)
    assert_response :not_found
    post bulk_approve_people_timesheets_path, params: { ids: [@b.sheet.id] }
    assert_equal 'draft', People::Timesheet.unscoped.find(@b.sheet.id).status
    get people_leave_request_path(@b.leave)
    assert_response :not_found
    get people_employee_path(@b.worker)
    assert_response :not_found
    post reset_people_employee_clock_pin_path(@b.worker)
    assert_response :not_found
    assert within(@b) { @b.worker.reload.pin_set? }
    period_b = within(@b) { PayPeriod.for_date(Date.new(2026, 7, 6)) }
    get people_pay_period_path(period_b)
    assert_response :not_found
    post lock_people_pay_period_path(period_b)
    assert_response :not_found
    assert_equal 'pending', ClockCorrection.unscoped.find(@b.correction.id).status

    # Exports and reports carry this workspace's rows only (the other shop worked 5 hours that day).
    get people_punch_history_path(format: :csv, from: '2026-07-01', to: '2026-07-31')
    assert_response :success
    assert_includes response.body, "Clock shift ##{@a.shift.id}"
    assert_not_includes response.body, "Clock shift ##{@b.shift.id}"
    get people_timesheets_path(format: :csv, status: 'all')
    assert_response :success
    assert_includes response.body, 'north hours'
    assert_not_includes response.body, 'south hours'
    period_a = within(@a) { PayPeriod.for_date(Date.new(2026, 7, 6)) }
    get people_pay_period_path(period_a, format: :csv)
    assert_response :success
    assert_equal 2, response.body.lines.size, 'the header and this workspace’s one worker'
  end

  test 'the staff API answers 404 for another workspace’s ids and scopes every list' do
    headers = app_token(@a.user)
    get '/api/v1/employee/timesheets', headers: headers
    assert_equal [@a.sheet.id], response.parsed_body['data'].map { |row| row['id'] }
    get "/api/v1/employee/timesheets/#{@b.sheet.id}", headers: headers
    assert_response :not_found
    post "/api/v1/employee/timesheets/#{@b.sheet.id}/actions/submit", headers: headers
    assert_response :not_found
    patch "/api/v1/employee/clock/#{@b.shift.id}", headers: headers
    assert_response :not_found
    post "/api/v1/employee/clock/#{@b.shift.id}/corrections", params: { clock_correction: { proposed_started_at: '2026-07-06T10:00:00Z', proposed_ended_at: '2026-07-06T12:00:00Z', reason: 'x' } }, headers: headers, as: :json
    assert_response :not_found
    post '/api/v1/employee/trades', params: { kind: 'give', shift_id: @b.planned.id }, headers: headers, as: :json
    assert_response :not_found
    get '/api/v1/employee/clock', headers: headers
    assert_equal [@a.shift.id], response.parsed_body['data'].map { |row| row['id'] }
    get '/api/v1/employee/schedule', params: { week: @a.planned.starts_at.to_date.iso8601 }, headers: headers
    assert_response :success
    ids = response.parsed_body['data'].map { |row| row['id'] }
    assert_not_includes ids, @b.planned.id
    get '/api/v1/employee/session', headers: headers
    assert_equal 'North Shop', response.parsed_body.dig('workspace', 'name')

    # A token is bound to its workspace: the other shop's host refuses the sign-in outright.
    host! "#{@b.tenant.subdomain}.example.com"
    post '/api/v1/employee/session', params: { email: @a.user.email, password: 'password123' }, as: :json
    assert_response :unauthorized
  end

  test 'the same PIN in two workspaces punches only the store the device belongs to' do
    login(@a.admin)
    post people_clock_devices_path, params: { name: 'North register' }
    assert cookies[ClockDevice::COOKIE].present?
    delete logout_path

    post clock_pin_path, params: { pin: '2580', clock_action: 'punch', request_token: SecureRandom.hex(8) }, as: :json
    assert_response :success
    assert_equal 'clocked_in', response.parsed_body['event']
    assert_equal 1, ClockShift.unscoped.open.where(employee_id: @a.worker.id).count
    assert_equal 0, ClockShift.unscoped.open.where(employee_id: @b.worker.id).count

    # The same browser, signed in to the other workspace: the North device vouches for nobody there.
    login(@b.admin)
    post clock_pin_path, params: { pin: '2580', clock_action: 'clock_out', request_token: SecureRandom.hex(8) }, as: :json
    assert_response :unprocessable_entity
    assert_equal 1, ClockShift.unscoped.open.where(employee_id: @a.worker.id).count, 'North’s punch is untouched'
    get clock_workers_path, as: :json
    assert_empty(response.parsed_body['data'].select { |row| row['id'] == @a.worker.id })
  end

  test 'PIN lockouts and PIN uniqueness are per workspace' do
    within(@a) { TimeRules.for.pin_lockout_attempts.times { @a.worker.verify_pin('0000') } }
    assert within(@a) { @a.worker.reload.pin_locked? }
    assert_not within(@b) { @b.worker.reload.pin_locked? }
    assert_nil within(@a) { TimeClockService.worker_by_pin('2580') }, 'locked in North'
    assert_equal @b.worker.id, within(@b) { TimeClockService.worker_by_pin('2580') }.id
    # A second South worker cannot take the PIN a South colleague has; North's use of it is irrelevant.
    within(@b) do
      other = People::Employee.create!(first_name: 'Kit', last_name: 'Lane', employment_type: 'part_time')
      assert_raises(ArgumentError) { TimeClockService.set_clock_pin!(other, '2580') }
      TimeClockService.set_clock_pin!(other, '4682')
    end
  end

  test 'an anonymous browser learns nothing about PINs, and the kiosk workers list is empty' do
    host! "#{@a.tenant.subdomain}.example.com"
    post clock_pin_path, params: { pin: '2580', clock_action: 'punch', request_token: SecureRandom.hex(8) }, as: :json
    real = [response.status, response.parsed_body['error']]
    post clock_pin_path, params: { pin: '9999', clock_action: 'punch', request_token: SecureRandom.hex(8) }, as: :json
    assert_equal real, [response.status, response.parsed_body['error']], 'a real PIN and a wrong one get the same answer'
    assert_equal 0, ClockShift.unscoped.open.count
    get clock_workers_path, as: :json
    assert_response :success
    assert_empty response.parsed_body['data']
  end

  test 'recurring jobs visit every workspace with its own rules and clock' do
    [@a, @b].each do |shop|
      within(shop) do
        ClockShift.create!(user: shop.user, employee: shop.worker, employee_key: shop.worker.id.to_s, employee_name: shop.worker.name,
          employment_type: shop.worker.employment_type, started_at: 7.hours.ago, request_token: SecureRandom.hex(12))
      end
    end
    # South turned break reminders off; North keeps the default.
    within(@b) { TimeRules.save!({ 'break_reminders' => false }, actor: @b.admin) }
    BreakReminderJob.perform_now
    assert Notification.unscoped.where(user_id: @a.user.id, kind: 'break_due').exists?
    assert_not Notification.unscoped.where(user_id: @b.user.id, kind: 'break_due').exists?
    assert_nil Current.tenant, 'no workspace is left behind after the job'

    LeaveAccrualJob.perform_now
    [@a, @b].each do |shop|
      balance = People::LeaveBalance.unscoped.find_by(tenant_id: shop.tenant.id, employee_id: shop.worker.id, leave_type: 'vacation')
      assert_equal 80, balance.accrued_hours.to_i, "#{shop.tenant.name} got its annual grant"
    end
  end

  test 'each workspace keeps its own clock: the same instants land on different days' do
    # 10:00 PM–11:30 PM Pacific on July 1 is 1:00–2:30 AM Eastern on July 2.
    started = Time.utc(2026, 7, 2, 5, 0)
    days = [@a, @b].to_h do |shop|
      day = within(shop) do
        shift = ClockShift.create!(user: shop.user, employee: shop.worker, employee_key: shop.worker.id.to_s, employee_name: shop.worker.name,
          employment_type: shop.worker.employment_type, started_at: started, ended_at: started + 90.minutes, request_token: SecureRandom.hex(12))
        sheet = People::Timesheet.create!(employee: shop.worker, period_start: '2026-06-29', period_end: '2026-07-05')
        TimesheetWorkflow.new(user: shop.admin).change(sheet, :import_shifts)
        sheet.entries.where(clock_shift_id: shift.id).pluck(:worked_on, :hours)
      end
      [shop.tenant.name, day]
    end
    assert_equal [[Date.new(2026, 7, 2), 1.5]], days['North Shop'].map { |d, h| [d, h.to_f] }, 'the instance default (Eastern)'
    assert_equal [[Date.new(2026, 7, 1), 1.5]], days['South Shop'].map { |d, h| [d, h.to_f] }, 'Pacific: still July 1'
    assert_equal 'America/Los_Angeles', within(@b) { Time.zone.tzinfo.name }
    assert_equal BusinessClock.default_zone.tzinfo.name, within(@a) { Time.zone.tzinfo.name }

    # A request runs on the signed-in workspace's clock too.
    login(@b.admin)
    get time_rules_settings_path
    assert_response :success
    assert_select 'select#tr_time_zone option[selected]', text: /Pacific/
    travel_to Time.utc(2026, 7, 2, 5, 30) do
      login(@b.user)
      get employee_app_path
      assert_response :success
      assert_includes response.body, 'Wednesday, July 1'
    end
  end

  test 'settings are stored per workspace and a new workspace starts with everything on' do
    within(@a) { TimeRules.save!({ 'scheduling_enabled' => false, 'punch_audit_trail' => true }, actor: @a.admin) }
    assert_not within(@a) { TimeRules.feature?(:scheduling) }
    assert within(@b) { TimeRules.feature?(:scheduling) }
    assert_not within(@b) { TimeRules.for(nil).punch_audit_trail? }
    fresh = Tenant.create!(name: 'Brand New', subdomain: "brand-new-#{SecureRandom.hex(3)}")
    Current.with_tenant(fresh) do
      TimeRules::FEATURES.each_key { |key| assert TimeRules.feature?(key), "#{key} is on by default" }
      assert_equal 'weekly', PayRules.current.pay_period
      assert_equal 5, TimeRules.for.pin_lockout_attempts
      assert_equal BusinessClock.default_zone.tzinfo.name, BusinessClock.zone.tzinfo.name
    end
    login(@a.user)
    get employee_schedule_path
    assert_redirected_to employee_app_path
    login(@b.user)
    get employee_schedule_path
    assert_response :success
  end

  test 'a phone’s push token follows the phone across workspaces and sign-outs' do
    first = within(@a) { PushDevice.register!(user: @a.user, platform: 'ios', token: 'one-phone') }
    second = within(@b) { PushDevice.register!(user: @b.user, platform: 'ios', token: 'one-phone') }
    assert first.reload.disabled_at.present?, 'the first person’s registration stopped'
    assert_nil second.reload.disabled_at
    assert_equal @b.tenant.id, second.tenant_id

    # The app forgets its token after the sign-out, with no session left.
    delete native_push_device_path(second.token_digest)
    assert_response :no_content
    assert PushDevice.unscoped.find(second.id).disabled_at.present?
    delete native_push_device_path('not-a-digest')
    assert_response :no_content

    # A deactivated account is never pushed to.
    within(@a) do
      device = PushDevice.register!(user: @a.user, platform: 'ios', token: 'old-phone')
      note = Notification.create!(tenant_id: @a.tenant.id, user_id: @a.user.id, kind: 'approvals', title: 'Approved')
      @a.user.update!(active: false)
      PushNotifier.stubs(:apns_configured?).returns(true)
      PushNotifier.expects(:deliver_apns).never
      PushNotifier.deliver(note)
      assert_nil device.reload.disabled_at
    end
  end

  test 'one email signs in to one workspace, and a second workspace is told so clearly' do
    within(@b) { People::Employee.create!(first_name: 'Sam', last_name: 'Twin', employment_type: 'part_time', email: @a.user.email) }
    twin = within(@b) { People::Employee.find_by!(last_name: 'Twin') }
    login(@b.admin)
    post employee_access_path(twin)
    assert_redirected_to people_employee_path(twin)
    assert_match(/One email signs in to one workspace/, flash[:alert])
    assert_nil within(@b) { twin.reload.user_id }
    assert_equal @a.tenant.id, @a.user.reload.tenant_id

    # On the other shop's address the first shop's account cannot sign in at all.
    delete logout_path
    host! "#{@b.tenant.subdomain}.example.com"
    post login_path, params: { email: @a.user.email, password: 'password123' }
    assert_response :unprocessable_entity
  end
end
