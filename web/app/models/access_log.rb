# frozen_string_literal: true

# One authentication event: who tried to get in, from where (IP), when, and
# whether it succeeded. Written on every login/oauth attempt and sign-out so
# access can be audited.
class AccessLog < ApplicationRecord
  include TenantScoped

  belongs_to :user, optional: true

  SOURCES = ["password", "google", "logout"].freeze
  STATUSES = ["success", "failure"].freeze

  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }, allow_nil: true

  scope :recent, ->(limit = 100) { order(created_at: :desc).limit(limit) }
  scope :for_email, ->(q) { where("email ILIKE ?", "%#{q.to_s.strip}%") }
end
