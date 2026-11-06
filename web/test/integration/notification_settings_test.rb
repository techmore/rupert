# frozen_string_literal: true

require 'test_helper'

# A person's own notification choices: every kind on by default, turned off per kind, honoured by
# TimeNotifier so a muted kind reaches neither the bell nor a phone.
class NotificationSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @worker_user = User.create!(tenant: @tenant, name: 'Quiet Worker', email: 'quiet-worker@example.com', role: 'employee', password: 'password123')
    People::Employee.create!(user: @worker_user, first_name: 'Quiet', last_name: 'Worker', employment_type: 'part_time')
    sign_in @worker_user
  end

  teardown { Current.reset }

  test 'an employee opens the settings page and turns a kind off' do
    get employee_notification_settings_path
    assert_response :success
    assert_select 'h1', 'Notifications'
    assert_select 'input[name^="prefs["][type=checkbox][checked]', User::NOTIFICATION_KINDS.size
    assert_select 'form[action=?]', employee_notification_settings_path
    patch employee_notification_settings_path, params: { prefs: { break_due: '0', schedule_posted: '1' } }
    assert_redirected_to employee_notification_settings_path
    prefs = @worker_user.reload.notification_prefs
    assert_equal false, prefs['break_due']
    assert_equal true, prefs['schedule_posted']
    assert_equal true, prefs['approvals'], 'a kind the form did not mention keeps its default (the form always sends every kind)'
  end

  test 'a muted kind is not delivered' do
    @worker_user.update!(notification_prefs: { 'break_due' => '0' })
    Current.reset
    Current.tenant = @tenant
    assert_no_difference -> { Notification.where(user_id: @worker_user.id).count } do
      TimeNotifier.break_due(@worker_user, shift: Struct.new(:id).new(1), kind: 'meal', url: '/employee')
    end
    assert_difference -> { Notification.where(user_id: @worker_user.id).count }, 1 do
      TimeNotifier.schedule_posted(@worker_user, week_start: Date.current, url: '/employee/schedule', shift_count: 2)
    end
  end
end
