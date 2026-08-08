# frozen_string_literal: true

class Setting < ApplicationRecord
  self.record_timestamps = false

  encrypts :value

  validates :key, presence: true, uniqueness: true

  before_save { self.updated_at = Time.current }
end
