# frozen_string_literal: true

# Original and proposed timestamps remain after review; approval changes the
# operational shift but never silently replaces the audit request.
class ClockCorrection < ApplicationRecord
  include TenantScoped
  include LockedPayPeriodGuard

  # Approving a correction changes hours on the original and the proposed dates; both must be open.
  guards_pay_period { status == 'approved' && status_changed? ? [original_started_at, original_ended_at, proposed_started_at, proposed_ended_at] : [] }

  belongs_to :clock_shift
  belongs_to :requester, class_name: 'User', foreign_key: :requested_by_id, optional: true
  belongs_to :reviewer, class_name: 'User', foreign_key: :reviewed_by_id, optional: true

  attr_readonly :tenant_id, :clock_shift_id, :requested_by_id, :original_started_at, :original_ended_at,
    :proposed_started_at, :proposed_ended_at, :reason
  validates :tenant_id, :reason, :original_started_at, :proposed_started_at, :proposed_ended_at, presence: true
  validates :reason, length: { maximum: 1000 }
  validates :status, inclusion: { in: %w[pending approved rejected] }
  validate :ordered_proposal
  validate :same_store

  # Who may approve or reject a correction (owner decision, 2026-11-02): anyone who reviews timesheets
  # (admins, managers, shift leaders) or holds payroll write. Never for their own shift (TimeClockService.review).
  def self.reviewer?(user)
    !!(user&.active? && (user.can_review_timesheets? || user.can?('payroll.write')))
  end

  private

  def ordered_proposal
    return if proposed_started_at.nil? || proposed_ended_at.nil?

    errors.add(:proposed_ended_at, 'must be after proposed clock-in') if proposed_ended_at <= proposed_started_at
    errors.add(:proposed_ended_at, 'cannot be in the future') if proposed_ended_at > Time.current
  end

  def same_store
    errors.add(:clock_shift, 'must belong to this store') unless clock_shift&.tenant_id == tenant_id
  end
end
