# frozen_string_literal: true

# Hourly read-only Square Loyalty refresh for workspaces that opted in, and the
# "Sync now" run on the Loyalty page (actor_id names who asked).
class SquareLoyaltySyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(tenant_id = nil, **) { tenant_id || 'scheduler' }, duration: 1.hour

  def perform(tenant_id = nil, actor_id: nil)
    unless tenant_id
      Tenant.where(status: 'active').find_each do |tenant|
        Current.set(tenant: tenant) do
          self.class.perform_later(tenant.id) if SquareLoyaltySync.enabled?
        end
      end
      return
    end
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) do
      EnvStore.clear_cache!
      actor_id ? SquareLoyaltySync.run(actor_id: actor_id) : SquareLoyaltySync.call
    end
  end
end
