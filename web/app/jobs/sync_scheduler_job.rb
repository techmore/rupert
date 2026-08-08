# frozen_string_literal: true

# Periodically enqueues a sync for every active, configured tenant.
class SyncSchedulerJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.where(status: "active").find_each do |tenant|
      Current.tenant = tenant
      next unless EnvStore.fetch("SHOPIFY_CLIENT_ID", "").present?

      SyncJob.perform_later(tenant_id: tenant.id, mode: "scheduled", actor: "scheduler")
    end
  ensure
    Current.tenant = nil
  end
end
