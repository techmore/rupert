# frozen_string_literal: true

module People
  # A weekly/batched time record for one employee: period bounds plus entries
  # per day. Moves draft -> submitted -> approved/rejected as a manager reviews.
  class Timesheet < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = "timesheets"

    belongs_to :employee, class_name: "People::Employee"
    belongs_to :reviewer, class_name: "User", foreign_key: :reviewed_by, optional: true
    has_many :entries, class_name: "People::TimesheetEntry", dependent: :destroy, inverse_of: :timesheet

    validates :period_start, :period_end, presence: true
    validate :period_end_after_start

    scope :recent, ->(limit = 200) { order(period_start: :desc).limit(limit) }
    scope :by_status, ->(status) { status.present? && status != "all" ? where(status: status) : all }
    scope :awaiting_review, -> { where(status: "submitted") }

    aasm column: "status", no_direct_assignment: true do
      state :draft, initial: true
      state :submitted
      state :approved
      state :rejected

      event :submit do
        transitions from: :draft, to: :submitted
      end
      event :approve do
        transitions from: :submitted, to: :approved
      end
      event :reject do
        transitions from: :submitted, to: :rejected
      end
      event :reopen do
        transitions from: [:approved, :rejected], to: :draft
      end
    end

    def total_hours
      entries.sum(:hours)
    end

    def regular_hours
      entries.where(work_type: "regular").sum(:hours)
    end

    def overtime_hours
      entries.where(work_type: "overtime").sum(:hours)
    end

    def period_label
      "#{period_start.strftime("%b %d")} – #{period_end.strftime("%b %d, %Y")}"
    end

    private

    def period_end_after_start
      return if period_start.nil? || period_end.nil?

      errors.add(:period_end, "must be after the start") if period_end < period_start
    end
  end
end
