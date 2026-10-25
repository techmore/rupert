# frozen_string_literal: true

require 'base64'
require 'digest'

# A file kept with a training module. Follows the Upload convention: the bytes are encrypted in the database (so the
# database backups carry them), the checksum is checked on every read, and the file never changes after it is saved
# (removing it only marks it removed).
# Untrusted: the type comes from the name and the bytes against a short allow-list, and it is only ever served as a
# download. Video files are not accepted; a module links to its video instead.
class TrainingAttachment < ApplicationRecord
  include TenantScoped

  MAX_BYTES = 10.megabytes
  MAX_PER_MODULE = 10
  TYPES = {
    '.pdf' => ['application/pdf', '%PDF'.b], '.png' => ['image/png', "\x89PNG".b], '.jpg' => ['image/jpeg', "\xFF\xD8\xFF".b],
    '.jpeg' => ['image/jpeg', "\xFF\xD8\xFF".b], '.gif' => ['image/gif', 'GIF8'.b], '.txt' => ['text/plain', nil], '.csv' => ['text/csv', nil]
  }.freeze
  ALLOWED_LABEL = 'PDF, PNG, JPG, GIF, TXT and CSV'

  encrypts :content_base64

  belongs_to :training_module
  belongs_to :uploaded_by, class_name: 'User', optional: true

  attr_readonly :tenant_id, :training_module_id, :filename, :content_type, :byte_size, :sha256, :content_base64

  validates :tenant_id, :filename, :content_type, :content_base64, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES, message: 'must be between 1 byte and 10 MB' }
  validates :sha256, format: { with: /\A\h{64}\z/ }
  validate :same_tenant_module
  validate :room_on_module, on: :create

  # An unsaved attachment for an uploaded file; it carries an error when the type is refused.
  def self.from_upload(training_module, upload, user)
    name = File.basename(upload.original_filename.to_s).gsub(/[^\w.\- ]/, '_').strip.last(120).presence || 'file'
    bytes = upload.read(MAX_BYTES + 1).to_s.b
    type, magic = TYPES[File.extname(name).downcase]
    attachment = new(training_module: training_module, tenant_id: training_module.tenant_id, uploaded_by: user, filename: name,
      byte_size: bytes.bytesize, content_type: type || 'application/octet-stream', sha256: Digest::SHA256.hexdigest(bytes),
      content_base64: Base64.strict_encode64(bytes))
    attachment.upload_error = "Only #{ALLOWED_LABEL} files can be added. Link to a video instead of uploading it." unless type
    attachment.upload_error = 'That file does not look like its extension.' if type && magic && !bytes.start_with?(magic)
    attachment
  end

  attr_accessor :upload_error

  validate { errors.add(:base, upload_error) if upload_error }
  before_destroy(prepend: true) { throw :abort }

  def removed? = removed_at.present?

  # Takes the file off the module for trainees; the bytes and the row stay for the history.
  def remove!(actor)
    update!(removed_at: Time.current, removed_by_id: actor&.id)
    training_module.bump_revision!
  end

  def bytes
    data = Base64.strict_decode64(content_base64)
    raise 'Training file checksum mismatch' unless Digest::SHA256.hexdigest(data) == sha256 && data.bytesize == byte_size

    data
  end

  private

  def same_tenant_module
    errors.add(:training_module, 'must belong to this workspace') unless training_module && training_module.tenant_id == tenant_id
  end

  def room_on_module
    return unless training_module && training_module.attachments.count >= MAX_PER_MODULE

    errors.add(:base, "A training module holds at most #{MAX_PER_MODULE} files")
  end
end
