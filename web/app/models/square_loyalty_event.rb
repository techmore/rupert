# frozen_string_literal: true

# One entry in the Square Loyalty points ledger, read-only mirror. Square ledger
# entries do not change, so a re-read of the same event updates nothing but last_seen_at.
class SquareLoyaltyEvent < ApplicationRecord
  include TenantScoped

  TYPES = %w[ACCUMULATE_POINTS CREATE_REWARD REDEEM_REWARD DELETE_REWARD ADJUST_POINTS EXPIRE_POINTS OTHER ACCUMULATE_PROMOTION_POINTS].freeze
  LABELS = {
    'ACCUMULATE_POINTS' => 'Earned', 'ACCUMULATE_PROMOTION_POINTS' => 'Promotion bonus', 'CREATE_REWARD' => 'Reward claimed',
    'REDEEM_REWARD' => 'Reward redeemed', 'DELETE_REWARD' => 'Reward cancelled', 'ADJUST_POINTS' => 'Adjusted',
    'EXPIRE_POINTS' => 'Expired', 'OTHER' => 'Other'
  }.freeze
  PILLS = {
    'ACCUMULATE_POINTS' => 'pill-fern', 'ACCUMULATE_PROMOTION_POINTS' => 'pill-fern', 'CREATE_REWARD' => 'pill-olive',
    'REDEEM_REWARD' => 'pill-olive', 'DELETE_REWARD' => 'pill-taupe', 'ADJUST_POINTS' => 'pill-clay', 'EXPIRE_POINTS' => 'pill-rose', 'OTHER' => 'pill-taupe'
  }.freeze

  attr_readonly :tenant_id, :external_id
  validates :external_id, :loyalty_account_external_id, :occurred_at, :last_seen_at, presence: true
  validates :external_id, uniqueness: { scope: :tenant_id }
  validates :event_type, inclusion: { in: TYPES }

  belongs_to :account, class_name: 'SquareLoyaltyAccount', primary_key: :external_id, foreign_key: :loyalty_account_external_id, optional: true

  def label
    LABELS.fetch(event_type, event_type.to_s.humanize)
  end

  def pill
    PILLS.fetch(event_type, 'pill-taupe')
  end

  # Points added (+) or removed (-) by this event. Square reports some amounts
  # unsigned, so the sign comes from the event type where the type fixes it.
  def self.points_change(event_type, points)
    return 0 unless points.is_a?(Integer)

    case event_type
    when 'CREATE_REWARD', 'EXPIRE_POINTS' then -points.abs
    when 'ACCUMULATE_POINTS', 'ACCUMULATE_PROMOTION_POINTS', 'DELETE_REWARD' then points.abs
    else points
    end
  end
end
