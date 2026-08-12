# frozen_string_literal: true

# A derived quantity proposal for one size SKU. In approval mode these are
# created "pending" and applied manually from the Reconcile screen; in auto
# mode they are applied to Square immediately and recorded as "applied".
class SizeChange < ApplicationRecord
  include TenantScoped

  STATUSES = ["pending", "applied", "failed", "skipped"].freeze

  belongs_to :family,
    class_name: "SizeFamily",
    foreign_key: "family_id",
    inverse_of: :size_changes

  validates :sku, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :target_quantity, numericality: { greater_than_or_equal_to: 0, allow_nil: true }

  scope :pending, -> { where(status: "pending") }
end
