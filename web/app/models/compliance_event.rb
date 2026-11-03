# frozen_string_literal: true

# The append-only compliance audit trail (F70): catalog and COA edits, blocked
# sales, manager PIN overrides (granted and refused), event open/close and
# event sales. Written in the same transaction as the change it records, so a
# change and its audit row commit or roll back together. Rows are never edited.
class ComplianceEvent < ApplicationRecord
  include TenantScoped

  ACTIONS = %w[
    category_saved catalog_item_approved catalog_item_edited catalog_item_suspended catalog_item_reinstated
    coa_added coa_withdrawn policy_changed override_pin_set
    sale_blocked override_granted override_refused
    event_created event_edited event_opened event_item_pulled event_closed event_sale event_sale_flagged
  ].freeze
  # Shown on the daily exception report and the owner alert.
  EXCEPTION_ACTIONS = %w[sale_blocked override_granted override_refused event_item_pulled event_sale_flagged].freeze

  belongs_to :user, optional: true
  belongs_to :approver, class_name: 'User', optional: true

  serialize :details_json, coder: JSON
  validates :action, inclusion: { in: ACTIONS }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :exceptions, -> { where(action: EXCEPTION_ACTIONS) }

  def readonly? = persisted?
  def details = details_json || {}
  def exception? = EXCEPTION_ACTIONS.include?(action)

  # Raises on failure: call inside the transaction of the change it records.
  def self.record!(action, subject: nil, location_id: nil, reason: nil, approver: nil, details: {}, pos_checkout_id: nil, pos_event_id: nil, actor: Current.user)
    create!(action: action, user_id: actor&.id, actor_name: actor&.display_name || actor&.email || 'system',
      approver_id: approver&.id, approver_name: approver && (approver.display_name || approver.email),
      subject_type: subject&.class&.name, subject_id: subject.try(:id)&.to_s, subject_label: label_for(subject),
      location_id: location_id || subject.try(:location_id), reason: reason.presence, details_json: details.presence,
      pos_checkout_id: pos_checkout_id, pos_event_id: pos_event_id)
  end

  def self.label_for(subject)
    case subject
    when ComplianceCatalogItem then subject.compliant_name
    when CertificateOfAnalysis then subject.label
    when PosEvent, ComplianceCategory, Location then subject.name
    when User then subject.display_name || subject.email
    when PosEventSale then "Event sale #{subject.id}"
    when PosCheckout then "Checkout #{subject.reference.to_s.first(8)}"
    end
  end
end
