# frozen_string_literal: true

# Ids generated in a cuid-like format for parity with the Prisma schema.
module HasCuid
  extend ActiveSupport::Concern

  included do
    before_create :assign_cuid
    self.record_timestamps = false
  end

  private

  def assign_cuid
    self.id = "c#{Time.now.to_i.to_s(36)}#{SecureRandom.alphanumeric(16)}" if id.blank?
  end
end
