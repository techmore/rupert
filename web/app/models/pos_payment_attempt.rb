# frozen_string_literal: true

class PosPaymentAttempt < ApplicationRecord
  include TenantScoped
  belongs_to :pos_checkout
  validates :invoice, :nonce_digest, :submitted_at, presence: true

  # Records a reconciliation check before any gateway request. True for the one
  # worker that may look this attempt up now; false when another worker claimed
  # it in the last two minutes or it is already resolved.
  def self.claim_reconciliation(id, statuses: %w[submitting unknown])
    where(id: id, status: statuses)
      .where('reconciliation_checked_at IS NULL OR reconciliation_checked_at < ?', 2.minutes.ago)
      .update_all(reconciliation_checked_at: Time.current) == 1
  end

  # Started by the phone app (Pos::DeviceReaderPayment) rather than the server.
  def device_reader? = provider == Pos::DeviceReader::PROVIDER

  # What the phone reported: a hint, never proof of payment.
  def device_report
    value = JSON.parse(device_report_json.presence || '{}')
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end
end
