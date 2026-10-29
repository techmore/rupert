# frozen_string_literal: true

# One Square version of a timecard as Rupert saw it, or the read where it went
# missing. Append-only: rows are never edited or removed.
class SquareTimecardVersion < ApplicationRecord
  KINDS = %w[seen missing].freeze
  include TenantScoped

  belongs_to :square_timecard
  belongs_to :employee, class_name: 'People::Employee', optional: true
  encrypts :payload
  attr_readonly :tenant_id, :square_timecard_id, :kind, :digest, :payload, :employee_id, :source_version, :source_updated_at, :seen_at
  validates :kind, inclusion: { in: KINDS }
  validates :seen_at, presence: true
  validates :digest, :payload, presence: true, if: -> { kind == 'seen' }
  validate :same_workspace
  before_update { raise ActiveRecord::ReadOnlyRecord, 'Square timecard versions are append-only' }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, 'Square timecard versions are append-only' }

  scope :chronological, -> { order(:seen_at, :id) }

  # Cards imported before this history existed: their first counted payload becomes version one.
  def self.baseline!(card)
    return if card.new_record? || card.source_payload.blank? || where(square_timecard_id: card.id).exists?

    create!(square_timecard: card, kind: 'seen', digest: card.original_digest || SquareTimecardImport.digest(JSON.parse(card.source_payload)),
      payload: card.source_payload, employee_id: card.employee_id, seen_at: card.imported_at || card.created_at)
  end

  # Appends a version when the source content or staff mapping differs from the last one seen.
  def self.record!(card, kind:, seen_at:, row: nil, digest: nil, employee_id: nil)
    baseline!(card)
    last = where(square_timecard_id: card.id).chronological.last
    return last if last && last.kind == kind && last.digest == digest && last.employee_id == employee_id

    create!(square_timecard: card, kind: kind, digest: digest, payload: row && JSON.generate(row), employee_id: employee_id, seen_at: seen_at,
      source_version: row && row['version'].is_a?(Integer) ? row['version'] : nil,
      source_updated_at: row && (Time.iso8601(row['updated_at']) rescue nil))
  end

  def row
    JSON.parse(payload.to_s)
  rescue JSON::ParserError
    {}
  end

  private

  def same_workspace
    errors.add(:square_timecard, 'must belong to this workspace') unless square_timecard&.tenant_id == tenant_id
  end
end
