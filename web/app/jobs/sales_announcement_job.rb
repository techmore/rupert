# frozen_string_literal: true

# Runs the static sales announcer after a sync. Safe by construction: the
# announcer no-ops when Buzz isn't configured or there's nothing new.
class SalesAnnouncementJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(tenant_id)
    tenant = Tenant.find(tenant_id)
    Current.tenant = tenant
    SalesAnnouncer.announce!
  ensure
    Current.tenant = nil
  end
end
