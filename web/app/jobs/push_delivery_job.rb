# frozen_string_literal: true

# Delivers one in-app Notification to the person's push devices. Delivery providers (APNs for the
# iPhone app, Web Push for installed web apps) are configured by environment; until one is, the job
# is never enqueued (`enabled?` is false) and the bell alone carries the message.
class PushDeliveryJob < ApplicationJob
  queue_as :default

  def self.enabled?
    PushNotifier.configured?
  rescue NameError
    false
  end

  def perform(notification_id)
    notification = Notification.unscoped.find_by(id: notification_id)
    return if notification.nil?

    Current.set(tenant: Tenant.find_by(id: notification.tenant_id)) do
      PushNotifier.deliver(notification)
    end
  end
end
