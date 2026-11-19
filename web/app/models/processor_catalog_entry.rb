# frozen_string_literal: true

# One approved SKU or category (or an excluded SKU) on a processor's list.
class ProcessorCatalogEntry < ApplicationRecord
  include TenantScoped

  KINDS = {
    'sku' => 'Approved SKU',
    'category' => 'Approved category',
    'excluded_sku' => 'Excluded SKU'
  }.freeze

  belongs_to :processor_catalog
  belongs_to :added_by, class_name: 'User', optional: true

  attr_readonly :tenant_id, :processor_catalog_id, :kind, :value, :normalized_value
  validates :kind, inclusion: { in: KINDS.keys }
  validates :value, presence: true, length: { maximum: 200 }
  validates :normalized_value, uniqueness: { scope: %i[processor_catalog_id kind] }
  validate do
    errors.add(:base, 'Catalog belongs to another workspace.') unless processor_catalog&.tenant_id == tenant_id
    errors.add(:value, 'contains unsupported characters') if value.to_s.match?(/[\x00-\x1f\x7f]/)
  end

  before_validation do
    self.value = value.to_s.squish
    self.normalized_value = self.class.normalize(kind, value)
  end

  # SKUs compare case-insensitively without surrounding space. Categories also
  # collapse inner whitespace, so "CBD  Tinctures" matches "cbd tinctures".
  def self.normalize(kind, value)
    text = value.to_s.unicode_normalize(:nfkc).squish
    kind.to_s == 'category' ? text.downcase : text.upcase
  end
end
