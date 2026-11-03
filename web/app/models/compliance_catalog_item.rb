# frozen_string_literal: true

# One owner-approved product on a store's locked register catalog (F70). It
# points at the store's native C-Trax variant and holds the compliant name the
# register and receipt show, its approved category and per-tender eligibility.
# Rupert enforces this list; deciding what is legal to sell is the owner's and
# counsel's call. Edits are recorded in ComplianceEvent.
class ComplianceCatalogItem < ApplicationRecord
  include TenantScoped

  STATUSES = %w[approved suspended].freeze
  SOURCES = %w[ctrax].freeze
  # Words processors and card networks read as medical claims or marijuana. A
  # compliant register or receipt name never contains them.
  RESTRICTED_NAME_TERMS = /\b(?:cures?|cured|treats?|treatment|heals?|healing|relief|relieves?|pain|anxiety|depression|insomnia|medical|medicinal|medicine|prescription|rx|dispensary|marijuana|weed|stoned|get high)\b/i

  belongs_to :location
  belongs_to :compliance_category
  has_many :certificates_of_analysis, class_name: 'CertificateOfAnalysis', dependent: :restrict_with_error
  has_many :pos_event_items, dependent: :restrict_with_error

  normalizes :compliant_name, :receipt_name, with: ->(value) { value.to_s.squish.presence }

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :source_variant_id, presence: true, length: { maximum: 255 }, uniqueness: { scope: %i[tenant_id location_id source] }
  validates :compliant_name, presence: true, length: { maximum: 80 }
  validates :receipt_name, length: { maximum: 40 }
  validates :thc_mg_per_container, numericality: { greater_than_or_equal_to: 0, less_than: 1_000_000 }, allow_nil: true
  validates :approved_price_cents, numericality: { only_integer: true, greater_than: 0, less_than: 100_000_000 }, allow_nil: true
  validate do
    %i[compliant_name receipt_name].each do |field|
      term = public_send(field).to_s[RESTRICTED_NAME_TERMS]
      errors.add(field, "uses “#{term}”, which reads as a health or marijuana claim") if term
    end
    if compliance_category&.prohibited && card_eligible
      errors.add(:card_eligible, 'cannot be on in a prohibited category')
    end
    unless [location, compliance_category].compact.all? { |row| row.tenant_id == tenant_id }
      errors.add(:base, 'Item belongs to another workspace.')
    end
  end

  scope :approved, -> { where(status: 'approved') }
  scope :ordered, -> { order(:compliant_name) }

  def approved? = status == 'approved'
  def receipt_label = receipt_name.presence || compliant_name
  def category_name = compliance_category&.name
  # The approved category, as processor allow-lists read it (F69 ProcessorCatalog#permits? reads sku and category).
  def category = category_name

  # The newest certificate that is current on +on+: not withdrawn, tested on or
  # before that day, within the policy's age limit and not past its expiry date.
  def current_coa(on: Date.current, max_age_days: CompliancePolicy::DEFAULT_COA_MAX_AGE_DAYS)
    candidates = certificates_of_analysis.loaded? ? certificates_of_analysis.to_a : certificates_of_analysis.where(status: 'current').to_a
    candidates.select { |coa| coa.current_on?(on, max_age_days: max_age_days) }.max_by { |coa| [coa.tested_on, coa.id] }
  end

  def latest_coa = certificates_of_analysis.reject(&:withdrawn?).max_by { |coa| [coa.tested_on, coa.id] }

  def audit_snapshot
    slice('compliant_name', 'receipt_name', 'status', 'card_eligible', 'cash_eligible', 'age_restricted', 'coa_required',
      'approved_price_cents', 'source_variant_id', 'sku').merge('category' => category_name,
        'thc_mg_per_container' => thc_mg_per_container&.to_s('F'))
  end
end
