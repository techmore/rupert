# frozen_string_literal: true

# One Square Loyalty member, read-only mirror. The member is linked to a Rupert
# customer only through the Square customer ID on the account, never by phone or name.
class SquareLoyaltyAccount < ApplicationRecord
  include TenantScoped

  encrypts :phone_number
  attr_readonly :tenant_id, :external_id
  validates :external_id, :program_external_id, :last_seen_at, presence: true
  validates :external_id, uniqueness: { scope: :tenant_id }

  has_many :events, class_name: 'SquareLoyaltyEvent', primary_key: :external_id, foreign_key: :loyalty_account_external_id

  scope :current, -> { where(source_present: true) }

  # Rupert customers synced from the same Square customer directory.
  def self.customers_by_square_id(square_customer_ids)
    ids = square_customer_ids.compact.uniq
    ids.empty? ? {} : Core::Customer.where(source: 'square', external_id: ids).index_by(&:external_id)
  end

  def self.for_customer(customer)
    return none unless customer&.source == 'square'

    where(square_customer_id: customer.external_id)
  end

  def customer
    return @customer if defined?(@customer)

    @customer = square_customer_id && Core::Customer.find_by(source: 'square', external_id: square_customer_id)
  end

  def expiring_deadlines
    JSON.parse(expiring_point_deadlines.presence || '[]').filter_map do |row|
      next unless row.is_a?(Hash) && row['points'].is_a?(Integer)

      { points: row['points'], expires_at: (Time.iso8601(row['expires_at']) rescue nil) }
    end
  rescue JSON::ParserError
    []
  end

  # Reward tiers the balance already covers, best first.
  def redeemable_tiers(tiers)
    tiers.select { |tier| tier.points.positive? && tier.points <= balance }.sort_by { |tier| -tier.points }
  end

  # The next tier the member is working towards, if any.
  def next_tier(tiers)
    tiers.select { |tier| tier.points > balance }.min_by(&:points)
  end

  # Last four digits only; the full number stays encrypted.
  def phone_hint
    digits = phone_number.to_s.gsub(/\D/, '')
    digits.length >= 4 ? "•••• #{digits[-4..]}" : nil
  end
end
