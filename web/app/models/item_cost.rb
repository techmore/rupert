# frozen_string_literal: true

# Cost of goods for one Shopify variant, entered in Rupert by a person with inventory write permission. Stored in
# Rupert only; nothing is written to Shopify, Square or C-Trax. ItemProfile prefers it over the C-Trax cost.
class ItemCost < ApplicationRecord
  include TenantScoped

  MAX_CENTS = 100_000_000

  belongs_to :updated_by, class_name: 'User', optional: true

  validates :shopify_variant_id, presence: true, length: { maximum: 120 }, uniqueness: { scope: :tenant_id }
  validates :cost_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: MAX_CENTS }

  # "6", "6.5", "$1,234.50" -> cents; nil when blank or not a plain non-negative amount.
  def self.parse_cents(text)
    Money.parse(text, negative: false)
  end

  # "Entered in Rupert by Jo on Oct 25, 2026"
  def note
    ['Entered in Rupert', updated_by&.display_name.presence&.then { "by #{it}" }, updated_at&.then { "on #{it.to_date.strftime('%b %-d, %Y')}" }].compact.join(' ')
  end
end
