# frozen_string_literal: true

# Read-only mirror of the seller's Square Loyalty program (Square allows one).
# Written only by SquareLoyaltyImport; nothing here is ever sent back to Square.
class SquareLoyaltyProgram < ApplicationRecord
  include TenantScoped

  ACCRUAL_LABELS = { 'VISIT' => 'Per visit', 'SPEND' => 'Per amount spent', 'ITEM_VARIATION' => 'Per item bought', 'CATEGORY' => 'Per category bought' }.freeze

  has_many :reward_tiers, class_name: 'SquareLoyaltyRewardTier', dependent: :restrict_with_exception
  has_many :promotions, class_name: 'SquareLoyaltyPromotion', dependent: :restrict_with_exception
  attr_readonly :tenant_id, :external_id
  validates :external_id, :last_seen_at, presence: true
  validates :external_id, uniqueness: { scope: :tenant_id }

  # The newest program read for this workspace.
  def self.current
    order(last_seen_at: :desc, id: :desc).first
  end

  def active?
    status == 'ACTIVE'
  end

  def point_word(count = 2)
    word = count.to_i.abs == 1 ? terminology_one : terminology_other
    word.presence || (count.to_i.abs == 1 ? 'point' : 'points')
  end

  def location_id_list
    JSON.parse(location_ids.presence || '[]')
  rescue JSON::ParserError
    []
  end

  def accrual_rule_list
    JSON.parse(accrual_rules.presence || '[]')
  rescue JSON::ParserError
    []
  end

  # "Points expire 12 months after they are earned", or nil when they never expire.
  def expiration_months
    expiration_duration.to_s[/\AP(\d+)M\z/, 1]&.to_i
  end
end
