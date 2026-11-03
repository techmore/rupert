# frozen_string_literal: true

# A reward a member can claim once their balance reaches +points+ (read-only mirror).
class SquareLoyaltyRewardTier < ApplicationRecord
  include TenantScoped

  belongs_to :program, class_name: 'SquareLoyaltyProgram', foreign_key: :square_loyalty_program_id
  attr_readonly :tenant_id, :external_id
  validates :external_id, :last_seen_at, :points, presence: true
  validates :external_id, uniqueness: { scope: :tenant_id }

  scope :current, -> { where(source_present: true) }
end
