# frozen_string_literal: true

class SyncRun < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = "SyncRun"
  self.primary_key = "id"

  scope :recent, ->(limit = 25) { order(startedAt: :desc).limit(limit) }

  def success?
    status == "success"
  end

  def failed?
    status == "failed"
  end

  has_many :movements,
    class_name: "InventoryMovement",
    foreign_key: "syncRunId",
    inverse_of: :sync_run
end
