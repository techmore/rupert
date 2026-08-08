# frozen_string_literal: true

module Goals
  class KpiReading < ApplicationRecord
    include TenantScoped

    self.table_name = "kpi_readings"

    belongs_to :kpi, class_name: "Goals::Kpi", foreign_key: :kpi_id

    validates :value, numericality: true
    validates :measured_at, presence: true
  end
end
