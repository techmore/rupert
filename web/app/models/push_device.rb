# frozen_string_literal: true

# A device that can receive push notifications for one sign-in: an iPhone APNs token (platform
# 'ios') or a browser Web Push subscription (platform 'web', keys in keys_json). The token is kept
# in full (it is the delivery address) and indexed by digest. A device that the provider rejects
# is disabled with the reason, never deleted, so a rejoined device is re-enabled in place.
class PushDevice < ApplicationRecord
  include TenantScoped

  PLATFORMS = %w[ios web].freeze

  belongs_to :user

  validates :platform, inclusion: { in: PLATFORMS }
  validates :token, presence: true, length: { maximum: 4000 }
  validates :token_digest, presence: true

  scope :active, -> { where(disabled_at: nil) }
  scope :for_user, ->(user) { where(user_id: user.id) }

  before_validation { self.token_digest = self.class.digest(token) if token.present? }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # Registers or refreshes a device for `user`; the same token re-registered by another account moves
  # to that account (one phone, one person signed in).
  def self.register!(user:, platform:, token:, environment: nil, app_version: nil, keys: nil)
    device = find_or_initialize_by(token_digest: digest(token))
    device.assign_attributes(user: user, platform: platform, token: token, environment: environment.presence,
      app_version: app_version.presence, keys_json: keys.present? ? keys.to_json : device.keys_json,
      last_seen_at: Time.current, disabled_at: nil, failure_reason: nil)
    device.save!
    device
  end

  def keys
    keys_json.present? ? JSON.parse(keys_json) : {}
  rescue JSON::ParserError
    {}
  end

  def disable!(reason)
    update!(disabled_at: Time.current, failure_reason: reason.to_s.truncate(200))
  end
end
