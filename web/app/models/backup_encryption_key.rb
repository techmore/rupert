# frozen_string_literal: true

require 'digest'

# The public half of an age key that backups are encrypted to (#421). Instance-wide (one database, one key).
#
# Lifecycle: created (pending) → activated when the owner types the check code printed on the recovery kit, which
# proves the kit was saved before any backup depends on it → retired when a newer key is activated. The backup
# scripts encrypt to the newest active key and refuse to run when there is none. Retired keys stay listed so a
# fingerprint next to an old backup file can be matched to the kit that opens it.
class BackupEncryptionKey < ApplicationRecord
  PENDING_FOR = 1.hour

  validates :recipient, presence: true, uniqueness: true
  validates :fingerprint, :confirmation_digest, presence: true
  validate :recipient_is_age_x25519

  before_validation { self.fingerprint = BackupEncryption::AgeKey.fingerprint(recipient) if recipient.present? }

  scope :active, -> { where.not(activated_at: nil).where(retired_at: nil) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  class << self
    def current = active.order(activated_at: :desc, id: :desc).first

    def digest(code) = Digest::SHA256.hexdigest(normalize_code(code))

    # Eight characters, grouped for reading off paper; no 0/O/1/I.
    def new_check_code = Array.new(8) { 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[SecureRandom.random_number(32)] }.join.insert(4, '-')

    def normalize_code(code) = code.to_s.upcase.gsub(/[^A-Z0-9]/, '')
  end

  def pending? = activated_at.nil? && retired_at.nil?
  def active? = activated_at.present? && retired_at.nil?
  def expired?(now = Time.current) = pending? && created_at < now - PENDING_FOR

  def state
    return 'retired' if retired_at
    return 'active' if activated_at

    expired? ? 'expired' : 'pending'
  end

  def code_matches?(code)
    ActiveSupport::SecurityUtils.secure_compare(self.class.digest(code), confirmation_digest.to_s)
  end

  # Make this the key new backups use. Earlier active keys are retired; their backups still open with their own kit.
  def activate!(actor:, now: Time.current)
    transaction do
      self.class.active.where.not(id: id).update_all(retired_at: now, updated_at: now)
      update!(activated_at: now, activated_by_id: actor&.id)
    end
  end

  private

  def recipient_is_age_x25519
    errors.add(:recipient, 'is not an age X25519 public key') unless BackupEncryption::AgeKey.valid_recipient?(recipient)
  end
end
