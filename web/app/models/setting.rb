# frozen_string_literal: true

class Setting < ApplicationRecord
  self.record_timestamps = false

  belongs_to :tenant, optional: true

  encrypts :value

  validates :key, presence: true, uniqueness: { scope: :tenant_id }

  before_save { self.updated_at = Time.current }

  # Setting is deliberately not TenantScoped: platform-wide keys live in rows
  # with a NULL tenant_id. Every read must therefore say which side it wants.
  # Use these helpers rather than hand-writing `tenant_id:` so an unfiltered
  # `Setting.where(key: ...)` stands out in review.
  scope :of_tenant, ->(tenant_id = Current.tenant_id) { where(tenant_id: tenant_id) }
  scope :platform, -> { where(tenant_id: nil) }

  # The row for +key+ owned by +tenant_id+ (the current workspace by default).
  def self.for_tenant(key, tenant_id = Current.tenant_id)
    find_by(key: key, tenant_id: tenant_id)
  end

  # The platform-wide (tenant_id NULL) row for +key+.
  def self.global(key)
    find_by(key: key, tenant_id: nil)
  end

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
