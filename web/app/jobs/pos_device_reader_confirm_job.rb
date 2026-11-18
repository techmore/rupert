# frozen_string_literal: true

# Asks the payment provider about one phone card reader attempt right after the
# phone reported (or cancelled), so the cashier is not left waiting for the next
# sweep. It only looks up: it never asks for a charge and is never retried. It
# claims the attempt the same way PosPaymentReconciliationJob does, so the two
# do not look up the same attempt at once; anything it leaves unresolved is
# picked up by that sweep.
class PosDeviceReaderConfirmJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(attempt_id, tenant_id)
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) do
      attempt = PosPaymentAttempt.find_by(id: attempt_id, provider: Pos::DeviceReader::PROVIDER)
      next unless attempt

      checkout = attempt.pos_checkout
      # Also claims an attempt Rupert already closed: a late report clears the
      # claim once, so it is looked up once and cannot be used to hammer the provider.
      next unless PosPaymentAttempt.claim_reconciliation(attempt.id, statuses: %w[submitting unknown declined])

      Pos::DeviceReaderPayment.reconcile!(attempt)
      PosInventoryJob.perform_later(checkout.id) if checkout.reload.paid? && !checkout.demo?
    rescue Pos::Error => e
      ActivityLogger.log('pos_payment_needs_review', subject: attempt, details: e.message)
    end
  end
end
