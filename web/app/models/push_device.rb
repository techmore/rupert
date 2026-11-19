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
  #
  # A token is one physical phone or browser. When it signs in to a different workspace (or as a
  # different person) every other registration of that token stops, in every workspace, so the last
  # person's schedule and approval notifications never reach the next person's lock screen.
  def self.register!(user:, platform:, token:, environment: nil, app_version: nil, keys: nil)
    device = unscoped.where(tenant_id: user.tenant_id).find_or_initialize_by(token_digest: digest(token))
    device.assign_attributes(user: user, platform: platform, token: token, environment: environment.presence,
      app_version: app_version.presence, keys_json: keys.present? ? keys.to_json : device.keys_json,
      last_seen_at: Time.current, disabled_at: nil, failure_reason: nil)
    device.tenant_id = user.tenant_id
    device.save!
    unscoped.where(token_digest: device.token_digest).where.not(id: device.id).where(disabled_at: nil)
      .update_all(disabled_at: Time.current, failure_reason: 'registered to another account', updated_at: Time.current)
    device
  end

  # Stops every device of `user` (offboarding, deactivation), or only one platform's (signing out
  # of the iPhone app). A user belongs to one workspace, so the user id is the scope.
  def self.disable_all_for(user, reason, platform: nil)
    return 0 unless user

    scope = unscoped.where(user_id: user.id, disabled_at: nil)
    scope = scope.where(platform: platform) if platform
    scope.update_all(disabled_at: Time.current, failure_reason: reason.to_s.truncate(200), updated_at: Time.current)
  end

  # Stops the phone or browser whose token has this digest, wherever it is registered. The digest
  # (SHA-256 of the device's own push token) is something only that device and this server know.
  def self.forget_token!(token_digest, reason: 'signed out')
    return 0 unless token_digest.to_s.match?(/\A\h{64}\z/)

    unscoped.where(token_digest: token_digest.to_s, disabled_at: nil).update_all(disabled_at: Time.current, failure_reason: reason, updated_at: Time.current)
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
