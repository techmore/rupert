# frozen_string_literal: true

# Runs the static sales announcer after a sync. Safe by construction: the
# announcer no-ops when Buzz isn't configured or there's nothing new.
class SalesAnnouncementJob < ApplicationJob
  queue_as :default

  def perform(tenant_id)
    tenant = Tenant.find(tenant_id)
    Current.tenant = tenant
    SalesAnnouncer.announce!
  rescue StandardError
    nil
  ensure
    Current.tenant = nil
  end
end
