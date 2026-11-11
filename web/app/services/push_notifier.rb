# frozen_string_literal: true

# Push delivery for one in-app Notification: APNs for the iPhone app (token-based auth over HTTP/2
# through apnotic) and Web Push (VAPID) for the installed staff web app. Both are configured by
# boot-time environment variables in /etc/rupert.env (docs/ops/environment-reference.md):
#
#   APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8 (the .p8 contents), APNS_TOPIC (com.rupertpos.Rupert),
#   APNS_ENVIRONMENT (sandbox | production)
#   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto: or https: URL)
#
# Until a provider is configured, `configured?` is false and PushDeliveryJob is never enqueued: the
# bell alone carries the message. A device the provider rejects for good (BadDeviceToken,
# Unregistered, 410 Gone) is disabled with the reason, never deleted.
class PushNotifier
  APNS_KEYS = %w[APNS_KEY_ID APNS_TEAM_ID APNS_KEY_P8 APNS_TOPIC].freeze
  VAPID_KEYS = %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT].freeze
  DEAD_APNS_REASONS = %w[BadDeviceToken Unregistered DeviceTokenNotForTopic].freeze

  Result = Struct.new(:sent, :disabled, :failed, keyword_init: true)

  class << self
    def configured?
      apns_configured? || web_push_configured?
    end

    def apns_configured? = APNS_KEYS.all? { |key| setting(key).present? }
    def web_push_configured? = VAPID_KEYS.all? { |key| setting(key).present? }

    # Sends `notification` to every active device of its user. Returns a Result with counts.
    def deliver(notification)
      result = Result.new(sent: 0, disabled: 0, failed: 0)
      # A deactivated account, or one in an inactive workspace, gets nothing on its lock screen.
      user = User.find_by(id: notification.user_id)
      return result unless user&.active? && user.tenant&.status == 'active'

      devices = PushDevice.active.where(user_id: notification.user_id).to_a
      return result if devices.empty?

      badge = Notification.where(user_id: notification.user_id).unread.count
      ios = devices.select { |d| d.platform == 'ios' }
      web = devices.select { |d| d.platform == 'web' }
      deliver_apns(ios, notification, badge, result) if ios.any? && apns_configured?
      deliver_web(web, notification, badge, result) if web.any? && web_push_configured?
      result
    end

    # The payload both channels carry: title, body, a deep link and the kind (thread) it belongs to.
    def payload(notification, badge)
      { title: notification.title.to_s, body: notification.body.to_s, url: notification.url.to_s, kind: notification.kind.to_s,
        notification_id: notification.id, badge: badge }
    end

    private

    # Platform-level keys (one app bundle, one VAPID pair for all workspaces): boot-time
    # environment only (/etc/rupert.env), never a tenant's managed settings.
    def setting(key)
      ENV.fetch(key, nil).presence
    end

    # ---- APNs ---------------------------------------------------------------------------------

    def deliver_apns(devices, notification, badge, result)
      connection = apns_connection
      devices.each { |device| apns_push(connection, device, notification, badge, result) }
    rescue StandardError => e
      # The connection itself failed (DNS, TLS, a bad key): every device counts as a failed send.
      result.failed += devices.size
      Rails.logger.warn("push: apns connection error #{e.class}: #{e.message}")
    ensure
      connection&.close
    end

    def apns_connection
      options = { auth_method: :token, cert_path: StringIO.new(setting('APNS_KEY_P8').to_s), key_id: setting('APNS_KEY_ID'), team_id: setting('APNS_TEAM_ID') }
      setting('APNS_ENVIRONMENT').to_s == 'production' ? Apnotic::Connection.new(options) : Apnotic::Connection.development(options)
    end

    def apns_push(connection, device, notification, badge, result)
      data = payload(notification, badge)
      push = Apnotic::Notification.new(device.token)
      push.topic = setting('APNS_TOPIC')
      push.alert = { title: data[:title], body: data[:body] }
      push.badge = badge
      push.sound = 'default'
      push.thread_id = data[:kind]
      push.category = 'rupert.time'
      push.custom_payload = { url: data[:url], kind: data[:kind], notification_id: data[:notification_id] }
      push.expiration = 1.day.from_now.to_i
      response = connection.push(push)
      if response.nil?
        result.failed += 1
      elsif response.ok?
        result.sent += 1
        device.update_columns(last_seen_at: Time.current)
      elsif response.status.to_i == 410 || DEAD_APNS_REASONS.include?(response.body.to_h['reason'])
        device.disable!(response.body.to_h['reason'] || 'gone')
        result.disabled += 1
      else
        result.failed += 1
        Rails.logger.warn("push: apns #{response.status} #{response.body.to_h['reason']} for device #{device.id}")
      end
    rescue StandardError => e
      result.failed += 1
      Rails.logger.warn("push: apns error #{e.class}: #{e.message}")
    end

    # ---- Web Push ----------------------------------------------------------------------------

    def deliver_web(devices, notification, badge, result)
      devices.each do |device|
        keys = device.keys
        WebPush.payload_send(message: payload(notification, badge).to_json, endpoint: device.token, p256dh: keys['p256dh'], auth: keys['auth'],
          vapid: { subject: setting('VAPID_SUBJECT'), public_key: setting('VAPID_PUBLIC_KEY'), private_key: setting('VAPID_PRIVATE_KEY') }, ttl: 86_400)
        result.sent += 1
        device.update_columns(last_seen_at: Time.current)
      rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription => e
        device.disable!(e.class.name.demodulize)
        result.disabled += 1
      rescue WebPush::ResponseError => e
        if e.response.respond_to?(:code) && %w[404 410].include?(e.response.code.to_s)
          device.disable!("gone #{e.response.code}")
          result.disabled += 1
        else
          result.failed += 1
          Rails.logger.warn("push: web push #{e.message} for device #{device.id}")
        end
      rescue StandardError => e
        result.failed += 1
        Rails.logger.warn("push: web push error #{e.class}: #{e.message}")
      end
    end
  end
end
