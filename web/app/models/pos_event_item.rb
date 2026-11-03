# frozen_string_literal: true

# One approved product offered at an event, with its preset price. The name,
# category, card eligibility and COA link are copied when the event opens so the
# register (and an offline queue) works from a frozen list; the live catalog
# item is still checked again when each sale is recorded.
class PosEventItem < ApplicationRecord
  include TenantScoped

  belongs_to :pos_event, inverse_of: :pos_event_items
  belongs_to :compliance_catalog_item

  validates :name, presence: true, length: { maximum: 80 }
  validates :price_cents, numericality: { only_integer: true, greater_than: 0, less_than: 100_000_000 }
  validates :loaded_quantity, :counted_remaining, numericality: { only_integer: true, in: 0..100_000 }, allow_nil: true
  validates :compliance_catalog_item_id, uniqueness: { scope: :pos_event_id }
  validate do
    if pos_event && compliance_catalog_item && compliance_catalog_item.location_id != pos_event.location_id
      errors.add(:base, 'Event items come from the event store’s approved catalog.')
    end
    unless [pos_event, compliance_catalog_item].compact.all? { |row| row.tenant_id == tenant_id }
      errors.add(:base, 'Event item belongs to another workspace.')
    end
  end

  def pulled? = pulled_at.present?

  # Copy the approved catalog facts the register shows and sells from. Card is
  # frozen on only when the card rules pass today (approved for card and a
  # current COA when one is required), so an offline device never offers a card
  # sale the server would refuse.
  def freeze_from_catalog!(on: Date.current, max_age_days: CompliancePolicy::DEFAULT_COA_MAX_AGE_DAYS)
    item = compliance_catalog_item
    coa = item.current_coa(on: on, max_age_days: max_age_days)
    line = Compliance::ItemEligibility::Line.new(key: id.to_s, name: item.receipt_label, catalog_item: item)
    card = Compliance::ItemEligibility.check([line], tender: 'card', on: on, policy: CompliancePolicy.new(coa_max_age_days: max_age_days)).allowed?
    update!(name: item.receipt_label, category_name: item.category_name, age_restricted: item.age_restricted, card_eligible: card,
      coa_url: coa&.document_url, coa_expires_on: coa&.current_until(max_age_days: max_age_days))
  end

  def register_payload
    { id: id, name: name, category: category_name, price_cents: price_cents, card_eligible: card_eligible,
      age_restricted: age_restricted, coa_url: coa_url, coa_expires_on: coa_expires_on&.iso8601 }
  end
end
