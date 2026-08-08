# frozen_string_literal: true

class SyncJob < ApplicationJob
  queue_as :default

  def perform(payload = {})
    mode = payload["mode"] || payload[:mode] || "manual"
    source = payload["source"] || payload[:source]
    actor = payload["actor"] || payload[:actor] || "scheduler"
    tenant_id = payload["tenant_id"] || payload[:tenant_id]

    tenant = Tenant.find(tenant_id) if tenant_id
    raise ArgumentError, "No tenant_id provided" if tenant.nil?

    Current.tenant = tenant

    if source.present?
      SyncEngine.run_source!(source, actor: actor, tenant: tenant)
    else
      SyncEngine.run!(mode: mode, actor: actor, tenant: tenant)
    end
  ensure
    Current.tenant = nil
  end
end
