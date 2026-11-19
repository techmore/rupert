# frozen_string_literal: true

class PosPaymentAttempt < ApplicationRecord
  include TenantScoped
  belongs_to :pos_checkout
  validates :invoice, :nonce_digest, :submitted_at, presence: true
  validates :entry_method, inclusion: { in: PaymentEntryMethod::VALUES }, allow_nil: true
end
