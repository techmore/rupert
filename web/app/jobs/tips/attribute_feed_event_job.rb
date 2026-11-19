# frozen_string_literal: true

module Tips
  # Attributes the tip on one Dejavoo FEED event (or settles its batch) right after the webhook stored it.
  class AttributeFeedEventJob < ApplicationJob
    queue_as :default

    def perform(event_id)
      event = DejavooFeedEvent.unscoped.find_by(id: event_id)
      return unless event

      tenant = Tenant.find_by(id: event.tenant_id)
      return unless tenant

      Current.with_tenant(tenant) do
        if event.event_type == 'Settlement'
          Tips::Reconciliation.new.settle_dejavoo_batch(event)
        else
          Tips::Attribution.call(event)
        end
      end
    end
  end
end
