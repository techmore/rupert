# frozen_string_literal: true

module Tips
  # After a reporting import or webhook refreshed Authorize.net transactions: attribute new tips,
  # settle the ones the gateway has now settled and reverse refunds/voids.
  class AttributeAuthorizeNetJob < ApplicationJob
    queue_as :default

    def perform(tenant_id:, transaction_ids: nil)
      tenant = Tenant.find_by(id: tenant_id, status: 'active')
      return unless tenant

      Current.with_tenant(tenant) do
        scope = AuthorizeNetTransaction.all
        scope = scope.where(id: transaction_ids) if transaction_ids
        scope.find_each { |txn| Tips::Reconciliation.new.authorize_net_transaction(txn) }
      end
    end
  end
end
