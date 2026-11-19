# frozen_string_literal: true

# Sends one saved Dejavoo Return to the terminal, where the customer presents
# the card. Never retried: a lost answer leaves the refund "unknown" until
# "Recheck refund status" resolves it from SPIn's Status.
class PosTerminalRefundJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(reversal_id)
    reversal = PosCardReversal.unscoped.find_by(id: reversal_id)
    checkout = reversal && PosCheckout.unscoped.find_by(id: reversal.pos_checkout_id)
    return unless checkout&.tenant&.status == 'active'

    Current.set(tenant: checkout.tenant) do
      Pos::CardReversal.run_dejavoo_refund!(PosCardReversal.find(reversal.id))
    rescue Pos::Error => e
      ActivityLogger.log('pos_card_reversal_needs_review', subject: checkout, details: e.message)
    end
  end
end
