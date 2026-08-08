# frozen_string_literal: true

# Canonical ERP tables use UUID string ids (portable across databases and
# safe to generate client-side for idempotent imports).
module UuidId
  extend ActiveSupport::Concern

  included do
    before_create :assign_uuid
    self.record_timestamps = true
  end

  private

  def assign_uuid
    self.id = SecureRandom.uuid if id.blank?
  end
end
