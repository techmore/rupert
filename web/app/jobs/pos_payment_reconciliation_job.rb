# frozen_string_literal: true

class PosPaymentReconciliationJob < ApplicationJob
  queue_as :default
  def perform
    PosPaymentAttempt.unscoped.joins(:tenant).where(tenants: { status: 'active' })
      .where(status: %w[submitting unknown]).where('submitted_at < ?', 1.minute.ago)
      .where('reconciliation_checked_at IS NULL OR reconciliation_checked_at < ?', 2.minutes.ago)
      .order(Arel.sql('COALESCE(reconciliation_checked_at, submitted_at)'), :id).limit(50).each do |attempt|
      # Record the attempt before network I/O, so failures cannot starve later payments.
      attempt.update_column(:reconciliation_checked_at, Time.current)
      Current.set(tenant: attempt.tenant) do
        Pos::CardPayment.reconcile!(attempt)
      rescue Pos::Error => e
        ActivityLogger.log('pos_payment_needs_review', subject: attempt, details: e.message)
      end
    end
  end
end
