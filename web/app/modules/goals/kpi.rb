# frozen_string_literal: true

module Goals
  class Kpi < ApplicationRecord
    include TenantScoped
    include UuidId

    self.table_name = "kpis"

    has_many :readings, class_name: "Goals::KpiReading", foreign_key: :kpi_id, dependent: :destroy

    validates :name, presence: true
    validates :direction, inclusion: { in: ["up", "down"] }

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }

    def latest_value
      readings.order(measured_at: :desc).first&.value
    end

    # Series of [time, value] for chartkick line charts.
    def series(days: 30)
      readings.where("measured_at >= ?", days.days.ago).order(measured_at: :asc)
        .pluck(:measured_at, :value)
    end

    def on_track?(current = latest_value)
      return true if current.nil?

      if direction == "up"
        current >= target_value.to_f
      else
        current <= target_value.to_f
      end
    end
  end
end
