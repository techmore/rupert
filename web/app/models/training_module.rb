# frozen_string_literal: true

require 'uri'

# One owner-made training module: instructions as text, up to ten files and an optional video link (#409 #410).
# The video is a link that opens on its own site: nothing is embedded, so the content security policy stays as it is.
# Every change to what a trainee reads (title, text, video link, files) raises `revision`, and a completion records
# the revision it was made against.
class TrainingModule < ApplicationRecord
  include TenantScoped

  CONTENT_FIELDS = %w[title body video_url].freeze
  BODY_LIMIT = 50_000

  # Removed files stay (soft-removed) so a completion's revision can still be traced to what was there.
  has_many :all_attachments, class_name: 'TrainingAttachment', dependent: :restrict_with_exception
  has_many :attachments, -> { where(removed_at: nil).order(:created_at, :id) }, class_name: 'TrainingAttachment'
  has_many :assignments, class_name: 'TrainingAssignment', inverse_of: :training_module, dependent: :restrict_with_exception
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  normalizes :title, with: ->(value) { value.to_s.squish }
  normalizes :video_url, with: ->(value) { value.to_s.strip.presence }

  validates :tenant_id, presence: true
  validates :title, presence: true, length: { maximum: 200 }
  validates :body, length: { maximum: BODY_LIMIT }
  validates :video_url, length: { maximum: 500 }
  validate :video_url_is_web_link

  before_update { self.revision = revision.to_i + 1 if (changed & CONTENT_FIELDS).any? }

  scope :ordered, -> { order(:title, :id) }

  # ActivityLogger and pickers label the module with this.
  def name = title

  # A file was added or removed: what a trainee sees has changed.
  def bump_revision!
    with_lock { update_columns(revision: revision + 1, updated_at: Time.current) }
  end

  private

  def video_url_is_web_link
    return if video_url.blank?

    uri = URI.parse(video_url)
    errors.add(:video_url, 'must be a full https:// link') unless uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    errors.add(:video_url, 'must be a full https:// link')
  end
end
