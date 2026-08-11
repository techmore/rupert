# frozen_string_literal: true

class Setting < ApplicationRecord
  self.record_timestamps = false

  belongs_to :tenant, optional: true

  encrypts :value

  validates :key, presence: true, uniqueness: { scope: :tenant_id }

  before_save { self.updated_at = Time.current }

  # Upsert-style write: applies the block to an existing row too, then saves.
  # Retries once if a concurrent writer wins the find_or_initialize race and we
  # hit the unique index.
  def self.find_or_create_for(key, tenant_id)
    record = find_by(key: key, tenant_id: tenant_id) || new(key: key, tenant_id: tenant_id)
    yield(record) if block_given?
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique
    retry if (record = find_by(key: key, tenant_id: tenant_id))
    raise
  end
end
