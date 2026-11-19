# frozen_string_literal: true

require 'test_helper'

# Settings → Time rules → "What is turned on" and "Punch logging": per-workspace switches for each
# part of the time system. Every switch is on by default (what Rupert did before), is saved only by
# someone with the settings permission, is written to the activity log old → new, and when off is
# refused by the server on the web pages, the staff API and the PIN clock, and leaves the menus.
class TimeFeaturesSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Switch Shop', subdomain: "switch-#{SecureRandom.hex(3)}")
    Current.tenant = @tenant
    @admin = User.create!(tenant: @tenant, name: 'Ada Admin', email: 'switch-admin@example.com', role: 'admin', password: 'password123')
    @manager = User.create!(tenant: @tenant, name: 'Mo Manager', email: 'switch-manager@example.com', role: 'manager', password: 'password123')
    @user = User.create!(tenant: @tenant, name: 'Wren Worker', email: 'switch-worker@example.com', role: 'employee', password: 'password123')
    @worker = People::Employee.create!(user: @user, first_name: 'Wren', last_name: 'Worker', employment_type: 'part_time', employee_number: 'W1', email: @user.email)
    @worker.set_pin!('2580')
  end

  teardown { Current.reset }

  # Rails clears Current after every request; the assertions between requests read this workspace.
  %i[get post patch delete].each do |verb|
    define_method(verb) do |*args, **options|
      super(*args, **options).tap do
        Current.reset
        Current.tenant = @tenant
      end
    end
  end

  def login(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password123' }
    assert_response :redirect
    Current.tenant = @tenant
  end

  def app_token(user = @user)
    post '/api/v1/employee/session', params: { email: user.email, password: 'password123', device_name: 'Test phone' }, as: :json
    assert_response :created
    Current.tenant = @tenant
    { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
  end

  def turn(values)
    Current.tenant = @tenant
    TimeRules.save!(values.transform_keys(&:to_s), actor: @admin)
  end

  def assert_feature_refused(feature)
    assert_response :forbidden
    assert_equal 'feature_disabled', response.parsed_body['error']
    assert_equal feature, response.parsed_body['feature']
  end

  def open_shift!
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: @worker.employment_type,
      started_at: 2.hours.ago, request_token: SecureRandom.hex(12))
  end

  test 'every switch is on by default and the page lists them for the workspace only' do
    TimeRules::FEATURES.each_key { |key| assert TimeRules.feature?(key), key }
    rules = TimeRules.for(nil)
    assert rules.punch_device_logging?
    assert_not rules.punch_audit_trail?
    assert_not rules.punch_ip_logging?
    assert_equal 7, rules.punch_audit_retention_years

    login(@admin)
    get time_rules_settings_path
    assert_response :success
    TimeRules::FEATURES.each_key { |key| assert_select "form#features input#tr_#{key}[checked]" }
    assert_select 'form#logging input#tr_punch_audit_trail:not([checked])'
    assert_select 'select#tr_time_zone'
  end

  test 'only someone who may save settings changes a switch, and the change is audited old to new' do
    login(@manager)
    post time_rules_settings_path, params: { section: 'features', time_rules: { clock_web_enabled: '1' } }
    assert TimeRules.feature?(:scheduling), 'a manager cannot turn anything off'
    login(@user)
    post time_rules_settings_path, params: { section: 'features', time_rules: {} }
    assert TimeRules.feature?(:scheduling)

    login(@admin)
    # Unchecked boxes are simply absent from the post.
    on = TimeRules::FEATURES.keys - %w[scheduling_enabled shift_trades_enabled]
    post time_rules_settings_path, params: { section: 'features', time_rules: on.index_with { '1' } }
    assert_redirected_to time_rules_settings_path(anchor: 'features')
    assert_not TimeRules.feature?(:scheduling)
    assert_not TimeRules.feature?(:shift_trades)
    assert TimeRules.feature?(:time_off)
    assert TimeRules.for(nil).rest_break_paid?, 'saving the switches leaves the rules’ own checkboxes alone'
    assert TimeRules.for(nil).punch_device_logging?, 'and the logging switches'

    log = ActivityLog.where(action: 'time_rules.updated').order(:id).last
    assert_equal @admin.id, log.user_id
    changes = JSON.parse(log.details).fetch('changes')
    assert_equal({ 'scheduling_enabled' => [true, false], 'shift_trades_enabled' => [true, false] }, changes)

    # Saving the rules form leaves the switches alone.
    post time_rules_settings_path, params: { section: 'rules', time_rules: { meal_break_minutes: 45, rest_break_paid: '1' } }
    assert_not TimeRules.feature?(:scheduling)
    assert_equal 45, TimeRules.for(nil).meal_break_minutes
    # Nothing changed, nothing logged.
    assert_no_difference -> { ActivityLog.where(action: 'time_rules.updated').count } do
      post time_rules_settings_path, params: { section: 'rules', time_rules: { meal_break_minutes: 45, rest_break_paid: '1' } }
    end
  end

  test 'the workspace time zone is chosen here, validated and audited' do
    login(@admin)
    post time_rules_settings_path, params: { section: 'rules', workspace_time_zone: 'America/Chicago', time_rules: { preset: 'federal' } }
    assert_equal 'America/Chicago', @tenant.reload.time_zone
    assert_equal ['time_zone'], JSON.parse(ActivityLog.where(action: 'time_rules.updated').order(:id).last.details)['changed']
    post time_rules_settings_path, params: { section: 'rules', workspace_time_zone: 'Mars/Olympus', time_rules: { preset: 'federal' } }
    assert_match(/not a known time zone/, flash[:alert])
    assert_equal 'America/Chicago', @tenant.reload.time_zone
    # A store cannot carry the workspace switches.
    store = Location.create!(name: 'Second store', source: 'rupert', externalId: 'second', active: true)
    post time_rules_settings_path, params: { section: 'features', location_id: store.id, time_rules: {} }
    assert_match(/whole workspace/, flash[:alert])
    assert TimeRules.feature?(:scheduling)
    TimeRules.save!({ 'scheduling_enabled' => false, 'meal_break_minutes' => 20 }, location_id: store.id, actor: @admin)
    assert TimeRules.feature?(:scheduling), 'a store override never carries a switch'
    assert_equal 20, TimeRules.for(store).meal_break_minutes
  end

  test 'clocking from the web, the app API, the register PIN and the kiosk each have a switch' do
    turn(clock_web_enabled: false)
    login(@user)
    post clock_in_time_clock_path, params: { request_token: SecureRandom.hex(12) }
    assert_redirected_to employee_app_path
    assert_match(/turned off/, flash[:alert])
    assert_equal 0, ClockShift.count
    get employee_app_path
    assert_select '[data-clock-channel-off]'
    assert_select "form[action='#{clock_in_time_clock_path}']", count: 0

    # The API is its own switch: still on.
    headers = app_token
    post '/api/v1/employee/clock', params: { request_token: SecureRandom.hex(12) }, headers: headers, as: :json
    assert_response :created
    assert_equal 'api', ClockShift.last.source
    turn(clock_app_enabled: false)
    patch "/api/v1/employee/clock/#{ClockShift.last.id}", headers: headers
    assert_feature_refused 'clock_app_enabled'
    get '/api/v1/employee/clock', headers: headers
    assert_response :success, 'reading own punches is not a punch'
    ClockShift.last.update_columns(ended_at: Time.current)

    # The PIN pad on the register and the kiosk.
    login(@user)
    post clock_pin_path, params: { pin: '2580', clock_action: 'punch', request_token: SecureRandom.hex(8) }, as: :json
    assert_response :success
    turn(clock_pin_enabled: false)
    post clock_pin_path, params: { pin: '2580', clock_action: 'clock_out', request_token: SecureRandom.hex(8) }, as: :json
    assert_feature_refused 'clock_pin_enabled'
    post clock_pin_path, params: { pin: '2580', clock_action: 'clock_out', request_token: SecureRandom.hex(8), kiosk: true }, as: :json
    assert_response :success, 'the kiosk is still on'
    turn(clock_kiosk_enabled: false)
    post clock_pin_path, params: { pin: '2580', clock_action: 'punch', request_token: SecureRandom.hex(8), kiosk: true }, as: :json
    assert_feature_refused 'clock_kiosk_enabled'
    get clock_kiosk_path
    assert_response :success
    assert_includes response.body, 'The clock kiosk is turned off'
    assert_select '#pin-clock', count: 0
  end

  test 'breaks, punch fixes by staff and self-submitted timesheets can be turned off' do
    shift = open_shift!
    turn(breaks_enabled: false)
    login(@user)
    post start_break_time_clock_path, params: { kind: 'rest' }
    assert_match(/Breaks and meals is turned off/, flash[:alert])
    assert_equal 0, ClockBreak.count
    post "/api/v1/employee/clock/#{shift.id}/breaks", params: { kind: 'meal' }, headers: app_token, as: :json
    assert_feature_refused 'breaks_enabled'
    login(@user)
    post clock_pin_path, params: { pin: '2580', clock_action: 'break', request_token: SecureRandom.hex(8) }, as: :json
    assert_feature_refused 'breaks_enabled'
    get employee_app_path
    assert_select "form[action='#{start_break_time_clock_path}']", count: 0

    shift.update_columns(ended_at: 1.hour.ago)
    turn(staff_corrections_enabled: false)
    fix = { clock_correction: { proposed_started_at: 3.hours.ago.iso8601, proposed_ended_at: 30.minutes.ago.iso8601, reason: 'Left later' } }
    post request_correction_time_clock_path(shift), params: fix
    assert_match(/Punch fixes by staff is turned off/, flash[:alert])
    post "/api/v1/employee/clock/#{shift.id}/corrections", params: fix, headers: app_token, as: :json
    assert_feature_refused 'staff_corrections_enabled'
    assert_equal 0, ClockCorrection.count
    # A manager still starts the fix for them.
    login(@manager)
    post request_correction_time_clock_path(shift), params: fix
    assert_equal 1, ClockCorrection.count

    turn(timesheet_self_submit: false)
    sheet = People::Timesheet.create!(employee: @worker, period_start: Date.current - 6, period_end: Date.current)
    sheet.entries.create!(worked_on: Date.current - 1, hours: 4, work_type: 'regular')
    login(@user)
    post submit_people_timesheet_path(sheet)
    assert sheet.reload.draft?
    post "/api/v1/employee/timesheets/#{sheet.id}/actions/submit", headers: app_token
    assert_response :unprocessable_entity
    assert_match(/manager submits/, response.parsed_body['message'])
    login(@manager)
    post submit_people_timesheet_path(sheet)
    assert sheet.reload.submitted?, 'the manager submits it'
  end

  test 'scheduling, trades, time off, pay and tips are refused and hidden when off' do
    planned = People::ScheduledShift.create!(employee: @worker, starts_at: 2.days.from_now.change(hour: 9), ends_at: 2.days.from_now.change(hour: 13), published_at: Time.current)
    headers = app_token
    turn(shift_trades_enabled: false)
    login(@user)
    get employee_schedule_path
    assert_response :success
    post employee_trades_path, params: { kind: 'give', shift_id: planned.id }
    assert_redirected_to employee_app_path
    post '/api/v1/employee/trades', params: { kind: 'give', shift_id: planned.id }, headers: headers, as: :json
    assert_feature_refused 'shift_trades_enabled'
    assert_equal 0, People::ShiftTrade.count

    turn(scheduling_enabled: false, time_off_enabled: false, pay_view_enabled: false)
    get employee_schedule_path
    assert_redirected_to employee_app_path
    get employee_time_off_path
    assert_redirected_to employee_app_path
    post employee_time_off_path, params: { leave_request: { leave_type: 'unpaid', starts_on: Date.current + 20, ends_on: Date.current + 20 } }
    assert_equal 0, People::LeaveRequest.count
    get employee_pay_path
    assert_redirected_to employee_app_path
    get employee_availability_index_path
    assert_redirected_to employee_app_path
    get '/api/v1/employee/schedule', headers: headers
    assert_feature_refused 'scheduling_enabled'
    get '/api/v1/employee/leave_requests', headers: headers
    assert_feature_refused 'time_off_enabled'
    get '/api/v1/employee/pay', headers: headers
    assert_feature_refused 'pay_view_enabled'

    login(@user)
    get employee_app_path
    assert_response :success
    assert_select 'nav.workspace-navigation a', text: 'Schedule', count: 0
    assert_select 'nav.workspace-navigation a', text: 'Time off', count: 0
    assert_select 'nav.workspace-navigation a', text: 'Pay', count: 0
    assert_select 'nav.workspace-navigation a', text: 'Timesheets', count: 1
    assert_not_includes response.body, employee_pay_path

    # Managers lose the schedule builder too, and the menu entry with it.
    login(@manager)
    get people_scheduled_shifts_path
    assert_redirected_to root_path
    assert_not_includes ModuleRegistry.nav_for(@manager).map(&:key), 'schedule'
    assert_not_includes ModuleRegistry.nav_for(@manager).map(&:key), 'shift_trades'
    assert_includes ModuleRegistry.nav_for(@manager).map(&:key), 'timesheets'

    # Tips alone: the Pay page stays, without tip figures or the cash-tip form.
    turn(scheduling_enabled: true, time_off_enabled: true, pay_view_enabled: true, tips_view_enabled: false)
    login(@user)
    get employee_pay_path
    assert_response :success
    assert_select '#tips', count: 0
    assert_select '#cash-tips', count: 0
    post declare_employee_tips_path, params: { cash_tips: { amount: '12.00', on: Date.current.iso8601 } }
    assert_redirected_to employee_app_path
    post '/api/v1/employee/tips', params: { cash_tips: { amount_cents: 1200, on: Date.current.iso8601 } }, headers: headers, as: :json
    assert_feature_refused 'tips_view_enabled'
    assert_equal 0, TipAllocation.count
    get '/api/v1/employee/pay', headers: headers
    assert_response :success
    assert_not response.parsed_body['data'].key?('tip_cents')
    assert_empty response.parsed_body['data']['tips']
  end

  test 'reminders can be turned off without touching anything else' do
    ClockShift.create!(user: @user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: @worker.employment_type,
      started_at: 20.hours.ago, request_token: SecureRandom.hex(12))
    turn(missed_clock_out_reminders: false)
    OpenClockOutAlertJob.perform_now
    assert_equal 0, Notification.unscoped.where(tenant_id: @tenant.id).count
    turn(missed_clock_out_reminders: true)
    OpenClockOutAlertJob.perform_now
    assert Notification.unscoped.where(tenant_id: @tenant.id, user_id: @user.id, kind: 'missed_clock_out').exists?
    assert Notification.unscoped.where(tenant_id: @tenant.id, kind: 'open_clock_out').exists?
  end

  test 'the punch audit trail, the network address and the device name are each a choice' do
    login(@user)
    post clock_in_time_clock_path, params: { request_token: SecureRandom.hex(12) }
    assert_equal 0, ActivityLog.where('action LIKE ?', 'time_clock.%').count, 'off by default: nothing is written'
    post clock_out_time_clock_path, params: { shift_id: ClockShift.last.id }

    turn(punch_audit_trail: true)
    travel 2.minutes
    post clock_in_time_clock_path, params: { request_token: SecureRandom.hex(12) }
    post start_break_time_clock_path, params: { kind: 'rest' }
    travel 1.minute
    post end_break_time_clock_path
    post clock_out_time_clock_path, params: { shift_id: ClockShift.order(:id).last.id }
    lines = ActivityLog.where('action LIKE ?', 'time_clock.%').order(:id)
    assert_equal %w[time_clock.clock_in time_clock.break_start time_clock.break_end time_clock.clock_out], lines.map(&:action)
    assert_equal @user.id, lines.first.user_id
    assert_equal 'People::Employee', lines.first.subject_type
    details = JSON.parse(lines.first.details)
    assert_equal 'web', details['source']
    assert_not details.key?('ip'), 'no network address unless that switch is on too'

    # Recording addresses needs the trail.
    assert_raises(TimeRules::Invalid) { turn(punch_audit_trail: false, punch_ip_logging: true) }
    turn(punch_ip_logging: true)
    post clock_pin_path, params: { pin: '0000', clock_action: 'punch', request_token: SecureRandom.hex(8) }, as: :json
    assert_response :unprocessable_entity
    Current.tenant = @tenant
    refused = ActivityLog.where(action: 'time_clock.pin_refused').last
    assert_equal '127.0.0.1', JSON.parse(refused.details)['ip']

    # Device and register names are kept by default and can be dropped.
    device, = ClockDevice.register!(name: 'Counter tablet', registered_by: @admin)
    shift = TimeClockService.pin_punch(pin: '2580', device: device, register_name: 'Till 1').shift
    assert_equal ['Counter tablet', 'Till 1'], [shift.device_label, shift.register_name]
    travel 1.minute
    TimeClockService.pin_punch(pin: '2580', action: 'clock_out', device: device)
    turn(punch_device_logging: false)
    travel 5.minutes
    shift = TimeClockService.pin_punch(pin: '2580', device: device, register_name: 'Till 1').shift
    assert_nil shift.device_label
    assert_nil shift.register_name
  end

  test 'old audit lines are removed after the chosen years; punches never are' do
    turn(punch_audit_trail: true, punch_audit_retention_years: 3)
    old = ActivityLog.create!(tenant_id: @tenant.id, action: 'time_clock.clock_in', created_at: 4.years.ago)
    recent = ActivityLog.create!(tenant_id: @tenant.id, action: 'time_clock.clock_in', created_at: 2.years.ago)
    other = ActivityLog.create!(tenant_id: @tenant.id, action: 'pay_period_locked', created_at: 4.years.ago)
    shift = open_shift!
    shift.update_columns(started_at: 5.years.ago, ended_at: 5.years.ago + 4.hours)
    DataRetentionJob.perform_now
    Current.tenant = @tenant
    assert_not ActivityLog.exists?(old.id)
    assert ActivityLog.exists?(recent.id)
    assert ActivityLog.exists?(other.id), 'the general activity log keeps its own seven years'
    assert ClockShift.exists?(shift.id)
    assert_raises(TimeRules::Invalid) { turn(punch_audit_retention_years: 1) }
  end

  # The whole path in a workspace nobody has configured: setup link → sign in → clock in, break,
  # clock out → timesheet → submit → approve → pay period → lock → export.
  test 'a brand-new worker in a brand-new workspace gets from a setup link to a payroll export' do
    recruit = People::Employee.create!(first_name: 'Nia', last_name: 'Newhire', employment_type: 'part_time', email: 'nia.newhire@example.com')
    People::PayRate.create!(employee: recruit, hourly_rate_cents: 2000, effective_on: Date.current - 30)
    login(@admin)
    post employee_access_path(recruit)
    assert_response :success
    token = response.body[%r{/employee/setup\?token=([A-Za-z0-9_-]+)}, 1]
    assert token.present?, 'the page shows the private setup link once'
    delete logout_path

    get employee_setup_path(token: token)
    assert_response :success
    patch employee_setup_path, params: { token: token, password: 'a-long-new-password', password_confirmation: 'a-long-new-password' }
    assert_redirected_to employee_app_path
    get employee_app_path
    assert_response :success
    assert_includes response.body, 'Nia'

    start = Time.current.beginning_of_day - 1.day + 9.hours
    travel_to(start) { post clock_in_time_clock_path, params: { request_token: SecureRandom.hex(12), return_to: 'home' } }
    Current.tenant = @tenant
    shift = ClockShift.find_by!(employee_id: recruit.id)
    travel_to(start + 3.hours) { post start_break_time_clock_path, params: { kind: 'meal' } }
    travel_to(start + 3.5.hours) { post end_break_time_clock_path }
    travel_to(start + 6.hours) { post clock_out_time_clock_path, params: { shift_id: shift.id } }
    Current.tenant = @tenant
    assert_in_delta 5.5, shift.reload.paid_hours, 0.01, 'six hours less the unpaid half-hour meal'

    post employee_week_path
    Current.tenant = @tenant
    sheet = People::Timesheet.find_by!(employee_id: recruit.id)
    assert_redirected_to people_timesheet_path(sheet)
    assert_equal 5.5, sheet.entries.sum(:hours).to_f, 'the finished shift was imported as paid hours'
    post submit_people_timesheet_path(sheet)
    assert sheet.reload.submitted?

    login(@manager)
    get people_approvals_path
    assert_response :success
    post approve_people_timesheet_path(sheet)
    Current.tenant = @tenant
    assert sheet.reload.approved?

    login(@admin)
    get people_pay_periods_path
    assert_response :success
    Current.tenant = @tenant
    period = PayPeriod.for_date(start.to_date)
    get people_pay_period_path(period)
    assert_response :success
    assert_includes response.body, 'Newhire'
    if period.ends_on < Date.current
      post lock_people_pay_period_path(period), params: { lock_anyway: '1', reason: 'First period' }
      Current.tenant = @tenant
      assert period.reload.locked?
    end
    get people_pay_period_path(period, format: :csv)
    assert_response :success
    row = CSV.parse(response.body, headers: true).find { |line| line.to_h.values.any? { |value| value.to_s.include?('Newhire') } }
    assert row, 'the export carries the new worker'
    assert_equal '5.50', row['regular_hours'], 'the export pays the hours the worker saw: the unpaid meal is not in them'
  end
end
