# frozen_string_literal: true

module Buzz
  # Brings one workspace's copy of its Buzz channels up to date. Started only by
  # the Team chat page's polling (at most every few seconds per workspace), never
  # on a schedule; never raises, because an unreachable relay is a state the page
  # shows, not an error.
  class SyncJob < ApplicationJob
    queue_as :default

    def perform(tenant_id)
      tenant = Tenant.find_by(id: tenant_id)
      return unless tenant

      previous = Current.tenant
      Current.tenant = tenant
      Buzz::Chat.sync!
    ensure
      Current.tenant = previous
    end
  end
end
