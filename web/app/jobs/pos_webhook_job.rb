# frozen_string_literal: true

# A signed gateway webhook arrived for this store: recheck its unresolved card
# payments and refunds through the gateway API (read-only). Nothing from the
# webhook body is trusted beyond which records to look at first.
class PosWebhookJob < ApplicationJob
  queue_as :default
  LIMIT = 20

  def perform(tenant_id:, setting_id:, transaction_id: nil, order_id: nil)
    tenant = Tenant.find_by(id: tenant_id, status: 'active')
    return unless tenant

    Current.set(tenant: tenant) do
      setting = PosSetting.find_by(id: setting_id)
      return unless setting

      checkouts = PosCheckout.where(location_id: setting.location_id, tender: 'card', gateway_provider: setting.gateway_provider)
      attempts = PosPaymentAttempt.where(pos_checkout_id: checkouts.select(:id), status: %w[submitting unknown])
      hinted = attempts.where(transaction_id: transaction_id.presence || '-').or(attempts.where(invoice: order_id.presence || '-'))
      (hinted.to_a + attempts.order(:submitted_at).limit(LIMIT).to_a).uniq.first(LIMIT).each do |attempt|
        Pos::CardPayment.reconcile!(attempt)
      rescue Pos::Error => e
        ActivityLogger.log('pos_payment_needs_review', subject: attempt, details: e.message)
      end
      PosCardReversal.unresolved.where(pos_checkout_id: checkouts.select(:id)).order(:submitted_at).limit(LIMIT).each do |reversal|
        Pos::CardReversal.reconcile!(reversal)
      rescue Pos::Error => e
        ActivityLogger.log('pos_card_reversal_needs_review', subject: reversal.pos_checkout, details: e.message)
      end
    end
  end
end
