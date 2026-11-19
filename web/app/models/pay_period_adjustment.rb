# frozen_string_literal: true

# Hours or money added to an open pay period for something that belongs to an earlier, locked one
# (an approved correction after the lock, a tip settled late, a missed bonus). The locked period's
# export never changes; the adjustment rides on the next file with its note.
class PayPeriodAdjustment < ApplicationRecord
  include TenantScoped

  KINDS = { 'hours' => 'Hours', 'overtime_hours' => 'Overtime hours', 'pto_hours' => 'Time off hours', 'tips' => 'Tips',
            'bonus' => 'Bonus', 'deduction' => 'Deduction', 'other' => 'Other' }.freeze
  HOUR_KINDS = %w[hours overtime_hours pto_hours].freeze

  belongs_to :pay_period
  belongs_to :employee, class_name: 'People::Employee'
  belongs_to :created_by, class_name: 'User', optional: true

  validates :kind, inclusion: { in: KINDS.keys }
  validates :note, presence: true, length: { maximum: 500 }
  validates :hours, numericality: { other_than: 0 }, if: :hours_kind?
  validates :amount_cents, numericality: { only_integer: true, other_than: 0 }, unless: :hours_kind?
  validate { errors.add(:base, 'This pay period is locked') if pay_period && pay_period.locked? && (new_record? || has_changes_to_save?) }

  def hours_kind? = HOUR_KINDS.include?(kind)
  def kind_label = KINDS.fetch(kind, kind)

  def label
    hours_kind? ? "#{format('%+g', hours.to_f)} h" : ActiveSupport::NumberHelper.number_to_currency(amount_cents / 100.0)
  end
end
