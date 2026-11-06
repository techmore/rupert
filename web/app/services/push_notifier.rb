# frozen_string_literal: true

# Push delivery. Stub until the notifications workstream wires APNs (token auth: APNS_KEY_ID,
# APNS_TEAM_ID, APNS_KEY_P8, APNS_TOPIC) and Web Push (VAPID keys). Keeps the interface stable:
# `configured?` gates enqueueing, `deliver(notification)` sends to every active PushDevice of the user.
class PushNotifier
  def self.configured?
    false
  end

  def self.deliver(_notification)
    nil
  end
end
