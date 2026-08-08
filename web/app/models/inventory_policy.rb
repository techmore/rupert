# frozen_string_literal: true

class InventoryPolicy < ApplicationRecord
  include TenantScoped

  self.table_name = "InventoryPolicy"
  self.primary_key = "sku"
  self.record_timestamps = false

  PRIORITIES = ["lowest", "shopify", "square"].freeze

  validates :priority, inclusion: { in: PRIORITIES }

  def self.priority_for(sku)
    find_by(sku: sku)&.priority || "lowest"
  end

  def self.set!(sku, priority, note: nil)
    record = find_or_initialize_by(sku: sku)
    record.priority = priority
    record.note = note if note
    record.updatedAt = Time.current
    record.save!
    record
  end
end
