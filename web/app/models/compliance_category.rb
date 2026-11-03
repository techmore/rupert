# frozen_string_literal: true

# An owner-approved product category for the locked register catalog (F70).
# `card_eligible` is the owner's reading of what the card processor approved;
# `prohibited` categories can never be rung up, whatever the tender.
class ComplianceCategory < ApplicationRecord
  include TenantScoped

  has_many :compliance_catalog_items, dependent: :restrict_with_error

  normalizes :name, with: ->(value) { value.to_s.squish }
  validates :name, presence: true, length: { maximum: 60 }, uniqueness: { scope: :tenant_id, case_sensitive: false }
  validates :notes, length: { maximum: 500 }
  validate { errors.add(:card_eligible, 'cannot be on for a prohibited category') if prohibited && card_eligible }

  scope :ordered, -> { order(:name) }

  def audit_snapshot = slice('name', 'card_eligible', 'prohibited', 'notes')
end
