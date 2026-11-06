# frozen_string_literal: true

# A store device (register browser, counter tablet) that a manager registered for PIN punches. The
# device keeps a long random token in a cookie; only the digest is stored. A PIN punch from an
# unregistered browser needs a signed-in account instead (buddy-punch prevention without GPS).
class ClockDevice < ApplicationRecord
  include TenantScoped

  COOKIE = 'rupert_clock_device'
  TOKEN_PREFIX = 'rcd_'

  belongs_to :location, optional: true
  belongs_to :registered_by, class_name: 'User', optional: true

  validates :name, presence: true, length: { maximum: 80 }
  validates :token_digest, presence: true

  scope :active, -> { where(revoked_at: nil) }

  # Registers a device and returns [device, secret]. The secret is shown once and set as the cookie.
  def self.register!(name:, location_id: nil, registered_by: Current.user)
    secret = TOKEN_PREFIX + SecureRandom.urlsafe_base64(32)
    device = create!(name: name, location_id: location_id.presence, registered_by: registered_by, token_digest: digest(secret), last_seen_at: Time.current)
    [device, secret]
  end

  def self.authenticate(secret)
    return nil if secret.blank? || !secret.to_s.start_with?(TOKEN_PREFIX)

    device = active.find_by(token_digest: digest(secret))
    device&.update_columns(last_seen_at: Time.current) if device && (device.last_seen_at.nil? || device.last_seen_at < 5.minutes.ago)
    device
  end

  def self.digest(secret) = Digest::SHA256.hexdigest(secret.to_s)

  def active? = revoked_at.nil?

  def revoke!
    update!(revoked_at: Time.current) if active?
  end
end
