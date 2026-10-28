# frozen_string_literal: true

class PosPaymentReconciliationJob < ApplicationJob
  queue_as :default

  def perform
    # SQLite deployments share one filesystem. An advisory process lock keeps
    # a slow gateway request from overlapping a later scheduled sweep; it is
    # released automatically if the worker exits.
    directory = lock_directory
    FileUtils.mkdir_p(directory)
    File.open(directory.join('pos-payment-reconciliation.lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      reconcile_batch
    ensure
      lock.flock(File::LOCK_UN)
    end
  end

  private

  def lock_directory = Rails.root.join('tmp/locks')

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
end
