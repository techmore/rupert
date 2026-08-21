# frozen_string_literal: true

# Ids generated in a cuid-like format for parity with the Prisma schema.
module HasCuid
  extend ActiveSupport::Concern

  class << self
    # Explicit generator for bulk writes (insert_all/upsert_all bypass
    # callbacks, so callers must provide ids themselves).
    def generate
      "c#{Time.now.to_i.to_s(36)}#{SecureRandom.alphanumeric(16)}"
    end
  end

  included do
    before_create :assign_cuid
    self.record_timestamps = false
  end

  private

  def assign_cuid
    self.id = HasCuid.generate if id.blank?
  end
end
