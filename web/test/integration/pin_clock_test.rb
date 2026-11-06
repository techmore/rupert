# frozen_string_literal: true

require 'test_helper'

# The PIN clock (time & pay: clock): the pad on the POS strip and the /clock kiosk, breaks, the
# forgotten clock-out fix, trusted devices, lockout and Spanish.
class PinClockTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = users(:regular_user)
    @user = User.create!(tenant: @tenant, name: 'Pin Worker', email: 'pin-clock@example.com', role: 'employee', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'Pia', last_name: 'Worker', employment_type: 'part_time', employee_number: 'E42')
    @worker.set_pin!('2580')
    @other_user = User.create!(tenant: @tenant, name: 'Other Worker', email: 'pin-other@example.com', role: 'employee', password: 'password')
    @other = People::Employee.create!(user: @other_user, first_name: 'Oli', last_name: 'Other', employment_type: 'part_time')
    @other.set_pin!('1357')
  end

  teardown { Current.reset }

  def login(user)
    delete logout_path
    post login_path, params: { email: user.email, password: 'password' }
    assert_response :redirect
    Current.tenant = @tenant
  end

  def punch(pin, action = 'punch', **extra)
    post clock_pin_path, params: { pin: pin, clock_action: action, request_token: SecureRandom.hex(8) }.merge(extra), as: :json
    response.parsed_body
  end

  def trust_device!
    login(@manager)
    post people_clock_devices_path, params: { name: 'Front register' }
    assert_redirected_to people_clock_devices_path
    assert cookies[ClockDevice::COOKIE].present?
    delete logout_path
  end

  test 'a trusted register clocks anyone in with four digits and offers clock out, break and meal when already in' do
    trust_device!
    travel_to Time.zone.parse('2026-11-06 09:02:00') do
      data = punch('2580')
      assert_equal 'clocked_in', data['event'], data.inspect
      assert_equal 'Clocked in · 9:02 AM ✓', data['message']
      assert_equal 'Pia', data['first_name']
      shift = ClockShift.find_by!(employee_id: @worker.id)
      assert_equal 'pos', shift.source
      assert_equal 'Front register', shift.device_label

      data = punch('2580')
      assert_equal 'already_in', data['event']
      assert_equal 'clocked_in', data['state']
      assert_nil data['fix_options']

      travel 2.hours
      data = punch('2580', 'meal')
      assert_equal 'meal_started', data['event']
      assert_equal 'On meal · 11:02 AM', data['message']
      assert shift.reload.on_break?
      assert_equal 'meal', shift.open_break.kind
      assert_not shift.open_break.paid?, 'meals are unpaid by default'

      travel 30.minutes
      assert_equal 'on_break', punch('2580')['state']
      data = punch('2580', 'end_break')
      assert_equal 'break_ended', data['event']
      assert_not shift.reload.on_break?

      travel 5.hours
      data = punch('2580', 'clock_out')
      assert_equal 'clocked_out', data['event']
      assert_equal 'Clocked out · 4:32 PM · 7.0 h', data['message']
      assert_in_delta 7.0, shift.reload.paid_hours, 0.01
      assert_in_delta 7.5, shift.hours, 0.01
    end
  end

  test 'a wrong PIN is refused and the pad never trusts an unregistered browser' do
    data = punch('2580')
    assert_response :unauthorized
    assert_equal false, data['ok']

    login(@user)
    data = punch('9999')
    assert_response :unprocessable_entity
    assert_equal 'That PIN didn’t match.', data['error']

    # Signed in as Pia, a colleague's PIN is refused on this phone.
    data = punch('1357')
    assert_response :unprocessable_entity
    assert_match(/someone else/, data['error'])
    assert_empty ClockShift.where(employee_id: @other.id)

    # Her own PIN works from her own session.
    data = punch('2580')
    assert_response :success
    assert_equal 'clocked_in', data['event']
    assert data['own']
  end

  test 'five wrong tries lock the PIN for the lockout window' do
    login(@user)
    rules = TimeRules.for
    assert_equal 5, rules.pin_lockout_attempts
    rules.pin_lockout_attempts.times { assert_not @worker.verify_pin('0000') }
    assert @worker.reload.pin_locked?
    data = punch('2580')
    assert_response :unprocessable_entity
    assert_equal 'That PIN didn’t match.', data['error']
    travel(rules.pin_lockout_minutes.minutes + 1.second) { assert_equal 'clocked_in', punch('2580')['event'] }

    # The pad itself locks too: five wrong PINs aimed at nobody in particular (counted in the cache).
    @worker.update!(pin_locked_until: nil)
    ClockShift.where(employee_id: @worker.id).delete_all
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    rules.pin_lockout_attempts.times { punch('0001') }
    data = punch('2580')
    assert_response :unprocessable_entity
    assert_match(/Too many wrong PINs/, data['error'])
  end

  test 'first use chooses a PIN on a trusted device by employee number and refuses runs and taken PINs' do
    trust_device!
    newcomer = People::Employee.create!(first_name: 'Nia', last_name: 'New', employment_type: 'part_time', employee_number: 'E77')
    get clock_workers_path, as: :json
    assert_includes response.parsed_body['data'].map { |w| w['name'] }, 'Nia New'
    assert_not_includes response.parsed_body['data'].map { |w| w['name'] }, 'Pia Worker', 'people with a PIN are not listed'

    post clock_pin_setup_path, params: { employee_number: 'E77', pin: '1234', pin_confirmation: '1234' }, as: :json
    assert_response :unprocessable_entity
    post clock_pin_setup_path, params: { employee_number: 'E77', pin: '2580', pin_confirmation: '2580' }, as: :json
    assert_response :unprocessable_entity
    assert_match(/taken/, response.parsed_body['error'])
    post clock_pin_setup_path, params: { employee_number: 'E77', pin: '4471', pin_confirmation: '4417' }, as: :json
    assert_response :unprocessable_entity
    post clock_pin_setup_path, params: { employee_number: 'E77', pin: '4471', pin_confirmation: '4471' }, as: :json
    assert_response :success
    assert_equal 'PIN saved, Nia. Type it to clock in.', response.parsed_body['message']
    assert newcomer.reload.pin_set?

    # A worker with no sign-in account can still punch from the register.
    data = punch('4471')
    assert_equal 'clocked_in', data['event']
    assert_nil ClockShift.find_by!(employee_id: newcomer.id).user_id
  end

  test 'a forgotten clock-out is fixed from the pad in two taps and files a correction' do
    trust_device!
    stale = nil
    travel_to Time.zone.parse('2026-11-04 09:00:00') do
      punch('2580')
      stale = ClockShift.find_by!(employee_id: @worker.id)
      People::ScheduledShift.create!(employee: @worker, starts_at: Time.zone.parse('2026-11-04 09:00'), ends_at: Time.zone.parse('2026-11-04 17:00'))
    end
    travel_to Time.zone.parse('2026-11-06 08:55:00') do
      data = punch('2580')
      assert_equal 'needs_fix', data['event']
      assert_equal 'You never clocked out on Wed', data['message']
      labels = data['fix_options'].map { |o| o['label'] }
      assert_includes labels, 'Planned end · 5:00 PM'
      assert_includes labels, '8 hours · 5:00 PM'

      assert_no_difference -> { ClockShift.count } do
        assert_equal false, punch('2580', 'fix_and_clock_in', proposed_ended_at: '2026-11-07T09:00')['ok'], 'a future clock-out is refused'
      end
      data = punch('2580', 'fix_and_clock_in', proposed_ended_at: data['fix_options'].first['at'])
      assert_equal 'fixed_and_clocked_in', data['event']
      assert_equal 'Clocked in · 8:55 AM ✓', data['message']

      stale.reload
      assert_equal Time.zone.parse('2026-11-04 17:00'), stale.ended_at
      assert stale.auto_closed_at.present?
      correction = stale.corrections.sole
      assert_equal 'pending', correction.status
      assert_nil correction.original_ended_at
      assert_equal 'Forgot to clock out.', correction.reason
      assert ClockShift.open.exists?(employee_id: @worker.id), 'today’s shift started'

      # The reviewer approves the time the worker gave; the shift already carries it.
      reviewer = @manager
      TimeClockService.review(correction: correction, reviewer: reviewer, approve: true)
      assert_equal 'approved', correction.reload.status
      assert Notification.where(user_id: @user.id, kind: 'approvals').exists?
    end
  end

  test 'signed-in breaks and fixes from the staff home and time clock, in Spanish' do
    login(@user)
    @worker.update!(locale: 'es')
    get employee_app_path
    assert_response :success
    assert_select 'button', 'Marcar entrada'
    post clock_in_time_clock_path, params: { request_token: SecureRandom.uuid, return_to: 'home' }
    assert_redirected_to employee_app_path
    follow_redirect!
    assert_match(/Entrada · \d+:\d\d [AP]M ✓/, response.body)
    assert_select 'button', 'Descanso'
    post start_break_time_clock_path, params: { kind: 'rest', return_to: 'home' }
    follow_redirect!
    assert_select 'button', 'Terminar descanso'
    assert_select '.pill-olive', /En descanso/
    post end_break_time_clock_path
    assert_redirected_to time_clock_path
    shift = ClockShift.find_by!(employee_id: @worker.id)
    assert_equal 1, shift.breaks.count
    travel 3.hours
    post clock_out_time_clock_path, params: { shift_id: shift.id }
    follow_redirect!
    assert_select 'summary', 'Corregir'

    # Fix a punch with a break change: original and proposed both kept until review.
    started = shift.reload.started_at
    post request_correction_time_clock_path(shift), params: { clock_correction: {
      proposed_started_at: (started - 15.minutes).strftime('%Y-%m-%dT%H:%M:%S'), proposed_ended_at: shift.ended_at.strftime('%Y-%m-%dT%H:%M:%S'),
      reason: 'Llegué antes', proposed_breaks: { '0' => { kind: 'meal', started_at: (started + 1.hour).iso8601, ended_at: (started + 90.minutes).iso8601 }, '1' => { kind: 'rest', started_at: '', ended_at: '' } }
    } }
    assert_redirected_to time_clock_path
    correction = shift.corrections.sole
    assert correction.changes_breaks?
    assert_equal 1, correction.original_breaks.size
    assert_equal 'meal', correction.proposed_breaks.first['kind']
    TimeClockService.review(correction: correction, reviewer: @manager, approve: true)
    assert_equal (started - 15.minutes).to_i, shift.reload.started_at.to_i
    assert_equal %w[meal], shift.breaks.map(&:kind)
    assert_in_delta 2.75, shift.paid_hours, 0.01
  end

  test 'settings page changes the language and PIN; manager page resets a PIN' do
    login(@user)
    get employee_devices_path
    assert_response :success
    assert_select 'h1', 'Settings'
    patch employee_settings_path, params: { locale: 'es' }
    assert_redirected_to employee_devices_path
    assert_equal 'es', @worker.reload.locale
    patch employee_settings_path, params: { pin: '8642', pin_confirmation: '8642' }
    assert @worker.reload.verify_pin('8642')
    patch employee_settings_path, params: { locale: 'fr' }
    assert_equal 'es', @worker.reload.locale
    delete logout_path

    login(@manager)
    get people_employee_path(@worker)
    assert_response :success
    assert_select '#clock-pin', /Set/
    post reset_people_employee_clock_pin_path(@worker)
    assert_redirected_to people_employee_path(@worker, anchor: 'access')
    assert_not @worker.reload.pin_set?
    post people_employee_clock_pin_path(@worker), params: { pin: '3141', pin_confirmation: '3141' }
    assert @worker.reload.verify_pin('3141')
  end

  test 'clock devices page lists, registers and revokes devices; the kiosk explains itself' do
    get clock_kiosk_path
    assert_response :success
    assert_match(/not registered/, response.body)
    login(@manager)
    get people_clock_devices_path
    assert_response :success
    assert_select 'h1', 'Clock devices'
    post people_clock_devices_path, params: { name: 'Counter tablet' }
    device = ClockDevice.sole
    get clock_kiosk_path
    assert_response :success
    assert_select '#pin-clock'
    delete people_clock_device_path(device)
    assert device.reload.revoked_at.present?
    get clock_kiosk_path
    assert_select '#pin-clock', count: 0 # no worker is linked to the manager, so the register form shows instead
    assert_match(/Register this device/, response.body)
  end

  test 'the employee role may reach the kiosk, the pad and the settings page and nothing else new' do
    login(@user)
    get clock_kiosk_path
    assert_response :success
    get people_clock_devices_path
    assert_redirected_to employee_app_path
    post reset_people_employee_clock_pin_path(@worker)
    assert_redirected_to employee_app_path
  end

  test 'break reminders fire once per kind when the thresholds pass' do
    login(@user)
    travel_to Time.zone.parse('2026-11-06 09:00:00') do
      post clock_in_time_clock_path, params: { request_token: SecureRandom.uuid }
      shift = ClockShift.find_by!(employee_id: @worker.id)
      assert_empty BreakReminderJob.due_kinds(shift)
      travel 4.hours
      assert_equal %w[rest], BreakReminderJob.due_kinds(shift.reload)
      travel 2.hours
      assert_equal %w[meal rest], BreakReminderJob.due_kinds(shift.reload)
      assert_difference -> { Notification.where(user_id: @user.id, kind: 'break_due').count }, 2 do
        BreakReminderJob.perform_now
        BreakReminderJob.perform_now
      end
    end
  end

  test 'the mobile API starts and ends breaks on the worker’s own shift' do
    EmployeeAppSession.stubs(:enabled?).returns(true)
    _session, token = EmployeeAppSession.issue!(user: @user, device_name: 'Test phone')
    headers = { 'Authorization' => "Bearer #{token}" }
    post '/api/v1/employee/clock', params: { request_token: SecureRandom.uuid }, headers: headers, as: :json
    assert_response :created
    shift_id = response.parsed_body['data']['id']
    post "/api/v1/employee/clock/#{shift_id}/breaks", params: { kind: 'meal' }, headers: headers, as: :json
    assert_response :created
    break_id = response.parsed_body['data']['id']
    patch "/api/v1/employee/clock/#{shift_id}/breaks/#{break_id}", headers: headers, as: :json
    assert_response :success
    assert response.parsed_body['data']['ended_at'].present?
    get '/api/v1/employee/clock', headers: headers, as: :json
    assert_equal 1, response.parsed_body['data'].first['breaks'].size
  end
end
