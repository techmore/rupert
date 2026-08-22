# frozen_string_literal: true

class ReconcileRun < ApplicationRecord
  include HasCuid
  include TenantScoped

  self.table_name = 'ReconcileRun'
  self.primary_key = 'id'

  has_many :items,
           class_name: 'ReconcileItem',
           foreign_key: 'runId',
           dependent: :destroy,
           inverse_of: :run

  scope :recent, ->(limit = 10) { order(startedAt: :desc).limit(limit) }
end
