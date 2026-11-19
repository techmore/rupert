# frozen_string_literal: true

# One Dejavoo FEED transaction or settlement, as Pos::DejavooFeed recorded it.
class DejavooFeedEvent < ApplicationRecord
  include TenantScoped

  belongs_to :pos_setting
  validates :feed_id, :request_type, :event_type, :received_at, presence: true

  scope :unmatched, -> { where(event_type: 'Transaction', matched_kind: nil) }

  def matched? = matched_kind.present?
end
