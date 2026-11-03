# frozen_string_literal: true

# A Square Loyalty promotion (extra or multiplied points), read-only mirror.
class SquareLoyaltyPromotion < ApplicationRecord
  include TenantScoped

  belongs_to :program, class_name: 'SquareLoyaltyProgram', foreign_key: :square_loyalty_program_id
  attr_readonly :tenant_id, :external_id
  validates :external_id, :last_seen_at, presence: true
  validates :external_id, uniqueness: { scope: :tenant_id }

  # "3× points" or "+50 points".
  def incentive_summary
    case incentive_type
    when 'POINTS_MULTIPLIER' then points_multiplier ? "#{points_multiplier}× points" : 'Multiplied points'
    when 'POINTS_ADDITION' then points_addition ? "+#{points_addition} points" : 'Extra points'
    else 'Promotion'
    end
  end

  def available_window
    data = JSON.parse(available_time.presence || '{}')
    [data['start_date'], data['end_date']]
  rescue JSON::ParserError
    [nil, nil]
  end
end
