# frozen_string_literal: true

class Setting < ApplicationRecord
  self.record_timestamps = false

  belongs_to :tenant, optional: true

  encrypts :value

  validates :key, presence: true, uniqueness: { scope: :tenant_id }

  before_save { self.updated_at = Time.current }
end
