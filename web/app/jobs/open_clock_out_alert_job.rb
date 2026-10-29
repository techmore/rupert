# frozen_string_literal: true

# Tells managers about forgotten clock-outs: each Rupert clock-in or Square timecard
# still open past the workspace's limit, once per shift (Notification dedupe_key).
class OpenClockOutAlertJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) { BusinessClock.use(tenant: tenant) { OpenClockOuts.new.notify_managers! } }
    rescue StandardError => e
      logger.error("#{self.class}: open clock-out alerts failed for tenant #{tenant.id}: #{e.class}")
    end
  end
end
