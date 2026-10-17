# frozen_string_literal: true

# Reviewed gross earnings only. These records never post payroll or payments.
class EmployeeEarningsPeriod < ApplicationRecord
  include TenantScoped
  COMPONENTS = %w[base tips store_commission online_commission bonus].freeze
  belongs_to :employee, class_name: 'People::Employee'
  validates :period_start, :period_end, :reviewed_at, presence: true
  validates :hours, numericality: { greater_than: 0, less_than_or_equal_to: 744 }
  validates(*COMPONENTS.map { |name| "#{name}_cents" }, numericality: { only_integer: true, greater_than_or_equal_to: 0 })
  validate do
    errors.add(:employee, 'must belong to this workspace') if employee && employee.tenant_id != tenant_id
    if period_start && period_end
      errors.add(:period_end, 'must cover 1–31 days') unless period_end >= period_start && period_end < period_start + 31
      overlapping = self.class.where(employee_id: employee_id).where.not(id: id).where('period_start <= ? AND period_end >= ?', period_end, period_start)
      errors.add(:base, 'A reviewed earnings period already overlaps these dates') if overlapping.exists?
    end
  end

  def total_cents
    COMPONENTS.sum { |name| public_send("#{name}_cents") }
  end

  def hourly_cents
    (total_cents / hours).round if hours&.positive?
  end

  def self.demo
    new(period_start: Date.current.beginning_of_week - 7, period_end: Date.current.beginning_of_week - 1,
      hours: 32, base_cents: 64000, tips_cents: 9600, store_commission_cents: 6400,
      online_commission_cents: 3200, bonus_cents: 1600, reviewed_at: Time.current).tap(&:readonly!)
  end
end
