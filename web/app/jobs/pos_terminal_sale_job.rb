# frozen_string_literal: true

# Sends one saved Dejavoo terminal attempt to the terminal and settles it. The
# customer can take up to two minutes at the terminal, so this never runs in a
# web request. It is never retried: a failed or lost answer leaves the checkout
# "unknown" for PosPaymentReconciliationJob to resolve from SPIn's Status.
class PosTerminalSaleJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(attempt_id)
    attempt = PosPaymentAttempt.unscoped.find_by(id: attempt_id)
    checkout = attempt && PosCheckout.unscoped.find_by(id: attempt.pos_checkout_id)
    return unless checkout&.tenant&.status == 'active'

    Current.set(tenant: checkout.tenant) do
      Pos::DejavooTerminalPayment.run!(PosPaymentAttempt.find(attempt.id))
      PosInventoryJob.perform_later(checkout.id) if checkout.reload.paid? && !checkout.demo?
    rescue Pos::Error => e
      ActivityLogger.log('pos_terminal_sale_unresolved', subject: checkout, details: e.message)
    end
  end
end
