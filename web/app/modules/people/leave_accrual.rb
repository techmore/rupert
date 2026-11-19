# frozen_string_literal: true

module People
  # One line of the leave ledger: why a balance went up (or down at a year-end cap).
  # LeaveBalance#accrued_hours is the running sum for that type and year.
  class LeaveAccrual < ApplicationRecord
    include TenantScoped

    self.table_name = 'leave_accruals'

    REASONS = { 'worked' => 'Accrued on hours worked', 'annual_grant' => 'Annual allowance', 'carryover' => 'Carried over from last year',
                'carryover_cap' => 'Carry-over cap', 'manual' => 'Set by an administrator' }.freeze

    belongs_to :employee, class_name: 'People::Employee'

    validates :leave_type, inclusion: { in: LeaveRequest::LEAVE_TYPES }
    validates :reason, inclusion: { in: REASONS.keys }
    validates :hours, numericality: { other_than: 0 }
    validates :year, presence: true

    scope :chronological, -> { order(:created_at, :id) }

    def reason_label = REASONS.fetch(reason, reason)
  end
end
