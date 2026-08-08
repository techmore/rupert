# frozen_string_literal: true

class ReconcileItem < ApplicationRecord
  include HasCuid

  self.table_name = "ReconcileItem"
  self.primary_key = "id"

  belongs_to :run, class_name: "ReconcileRun", foreign_key: "runId",
    inverse_of: :items

  scope :for_run, ->(run_id) { where(runId: run_id) }
end
