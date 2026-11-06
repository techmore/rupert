# frozen_string_literal: true

module Tips
  # Hourly: settle estimated tip allocations against settled gateway money for every active workspace.
  class ReconcileJob < ApplicationJob
    queue_as :default

    def perform
      Tenant.where(status: 'active').find_each do |tenant|
        Current.set(tenant: tenant) { Tips::Reconciliation.new.run }
      rescue StandardError => e
        Rails.logger.warn("[tips] reconciliation failed for #{tenant.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
