# frozen_string_literal: true

class PosPaymentReconciliationJob < ApplicationJob
  queue_as :default

  def perform
    # SQLite deployments share one filesystem. An advisory process lock keeps
    # a slow gateway request from overlapping a later scheduled sweep; it is
    # released automatically if the worker exits.
    FileUtils.mkdir_p(lock_path.dirname)
    File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      reconcile_batch
      reconcile_reversals
    ensure
      lock.flock(File::LOCK_UN)
    end
  end

  private

  def lock_path
    Rails.root.join('tmp/locks/pos-payment-reconciliation.lock')
  end

  def reconcile_batch
    PosPaymentAttempt.unscoped.joins(:tenant).where(tenants: { status: 'active' })
      .where(status: %w[submitting unknown]).where('submitted_at < ?', 1.minute.ago)
      .where('reconciliation_checked_at IS NULL OR reconciliation_checked_at < ?', 2.minutes.ago)
      .order(Arel.sql('COALESCE(reconciliation_checked_at, submitted_at)'), :id).limit(50).each do |attempt|
      Current.set(tenant: attempt.tenant) do
        # Record the check before network I/O so unresolved or failed checks
        # rotate behind attempts that have not been checked yet.
        claimed = PosPaymentAttempt.where(id: attempt.id, status: %w[submitting unknown])
          .where('reconciliation_checked_at IS NULL OR reconciliation_checked_at < ?', 2.minutes.ago)
          .update_all(reconciliation_checked_at: Time.current)
        next unless claimed == 1

        Pos::CardPayment.reconcile!(attempt)
      rescue Pos::Error => e
        ActivityLogger.log('pos_payment_needs_review', subject: attempt, details: e.message)
      end
    end
  end

  # Voids/refunds whose gateway response was lost: read-only rechecks, never resent.
  def reconcile_reversals
    PosCardReversal.unscoped.joins(:tenant).where(tenants: { status: 'active' })
      .where(status: %w[submitting unknown]).where('pos_card_reversals.submitted_at < ?', 1.minute.ago)
      .where('pos_card_reversals.updated_at < ?', 2.minutes.ago).order(:updated_at, :id).limit(20).each do |reversal|
      Current.set(tenant: reversal.tenant) do
        PosCardReversal.where(id: reversal.id).update_all(updated_at: Time.current)
        Pos::CardReversal.reconcile!(reversal)
      rescue Pos::Error => e
        ActivityLogger.log('pos_card_reversal_needs_review', subject: reversal.pos_checkout, details: e.message)
      end
    end
  end
end
