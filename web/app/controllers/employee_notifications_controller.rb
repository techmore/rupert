# frozen_string_literal: true

# A person's own notification choices (which time & pay events reach them) and the installed web
# app's Web Push subscription. Both act on Current.user alone; no other person's settings are read.
class EmployeeNotificationsController < ApplicationController
  layout 'employee'
  before_action { response.headers['Cache-Control'] = 'no-store' }

  KIND_LABELS = {
    'schedule_posted' => ['Schedule posted', 'When a week of shifts is published.'],
    'schedule_changed' => ['Schedule changed', 'When one of your shifts moves or is cancelled.'],
    'approvals' => ['Approvals', 'When a time-off request, correction or trade is decided, or (for managers) waits for you.'],
    'trade_offers' => ['Shift offers', 'When a colleague offers a shift or an open shift needs cover.'],
    'missed_clock_out' => ['Forgotten clock-out', 'When a shift of yours is still open long after it should have ended.'],
    'break_due' => ['Break reminders', 'When it is time for a break or a meal on a long shift.'],
    'timesheet' => ['Timesheets', 'When your timesheet is approved or returned.']
  }.freeze

  def settings
    @prefs = Current.user.notification_prefs
    @devices = PushDevice.active.where(user_id: Current.user.id).order(:platform, :created_at)
    @vapid_public_key = PushNotifier.web_push_configured? ? ENV.fetch('VAPID_PUBLIC_KEY', nil) : nil
  end

  def update_settings
    Current.user.notification_prefs = params.fetch(:prefs, {}).permit(*User::NOTIFICATION_KINDS).to_h
    Current.user.save!
    redirect_to employee_notification_settings_path, notice: 'Notification choices saved.'
  end

  # POST /employee/push_subscriptions {subscription: {endpoint, keys: {p256dh, auth}}} from the installed web app.
  def subscribe
    subscription = params.require(:subscription)
    endpoint = subscription[:endpoint].to_s
    keys = subscription[:keys].respond_to?(:to_unsafe_h) ? subscription[:keys].to_unsafe_h.slice('p256dh', 'auth') : {}
    if endpoint.blank? || !endpoint.start_with?('https://') || keys.size != 2 || keys.values.any?(&:blank?)
      return render(json: { error: 'A push subscription needs an https endpoint and keys.' }, status: :unprocessable_entity)
    end

    device = PushDevice.register!(user: Current.user, platform: 'web', token: endpoint, keys: keys, app_version: 'web')
    render json: { id: device.id, push_configured: PushNotifier.configured? }, status: :created
  end

  def unsubscribe
    device = PushDevice.find_by(user_id: Current.user.id, id: params[:id])
    device&.disable!('turned off')
    redirect_to employee_notification_settings_path, notice: 'Push turned off for that device.'
  end
end
