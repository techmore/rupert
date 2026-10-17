# frozen_string_literal: true

class BankFeedSyncJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: ->(tenant_id = nil) { tenant_id || 'scheduler' }, duration: 30.minutes

  def perform(tenant_id = nil)
    unless tenant_id
      Tenant.where(status: 'active').find_each do |tenant|
        Current.set(tenant: tenant) do
          self.class.perform_later(tenant.id) if BankConnection.where(sync_enabled: true).exists?
        end
      end
      return
    end
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant
    Current.set(tenant: tenant) do
      connection = BankConnection.find_by(sync_enabled: true)
      return unless connection
      begin
        BankFeed::Sync.call(connection)
      rescue BankFeed::PlaidClient::Error
        # Sanitized error code is saved by the sync service for the finance UI.
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ReconciliationEvidence::Error
        connection.update!(last_error_code: 'REVIEW_REQUIRED')
      end
    end
  end
end
