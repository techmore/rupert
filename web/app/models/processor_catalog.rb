# frozen_string_literal: true

# The products one card processor approved for this workspace (F69).
#
# Card networks only allow products inside the federal hemp definition, and a
# hemp/CBD acquirer underwrites the merchant's exact catalog. When `enforced` is
# on, Rupert charges an item on this processor only if its SKU or category is on
# the list (and its SKU is not explicitly excluded). Whether a product is legal
# is the merchant's and counsel's decision; Rupert only enforces their list.
class ProcessorCatalog < ApplicationRecord
  include TenantScoped

  PROCESSORS = {
    'authorize_net' => 'Authorize.net',
    'nmi' => 'NMI',
    'card_terminal' => 'Card terminal (standalone)'
  }.freeze

  belongs_to :approved_by, class_name: 'User', optional: true
  has_many :entries, class_name: 'ProcessorCatalogEntry', dependent: :delete_all

  validates :processor, inclusion: { in: PROCESSORS.keys }, uniqueness: { scope: :tenant_id }
  validates :approval_reference, length: { maximum: 200 }
  validates :approval_note, length: { maximum: 2000 }
  validate do
    if enforced && approval_reference.blank?
      errors.add(:approval_reference, "is required before enforcing: record the processor's approval (for example the approval email date or case number)")
    end
    errors.add(:base, 'Approver must belong to this workspace.') if approved_by && approved_by.tenant_id != tenant_id
  end

  def label = PROCESSORS.fetch(processor, processor)

  def self.label_for(processor) = PROCESSORS.fetch(processor.to_s, processor.to_s.humanize)

  # Normalized lookup sets, loaded once per check.
  def lookup
    @lookup ||= entries.pluck(:kind, :normalized_value).each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |(kind, value), sets|
      sets[kind] << value
    end
  end

  def reload(*)
    @lookup = nil
    super
  end
end
