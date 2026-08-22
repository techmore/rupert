# frozen_string_literal: true

module People
  # A batch of payslips for one pay period. Draft until finalized (totals
  # locked in) and paid once money goes out.
  class PayRun < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'pay_runs'

    has_many :payslips, class_name: 'People::Payslip', dependent: :destroy, inverse_of: :pay_run

    validates :name, presence: true
    validates :period_start, :period_end, presence: true
    validate :period_end_after_start

    scope :recent, ->(limit = 100) { order(period_end: :desc).limit(limit) }
    scope :by_status, ->(status) { status.present? && status != 'all' ? where(status: status) : all }

    aasm column: 'status', no_direct_assignment: true do
      state :draft, initial: true
      state :finalized
      state :paid

      event :finalize do
        transitions from: :draft, to: :finalized
      end
      event :pay do
        transitions from: :finalized, to: :paid
      end
    end

    def total_gross_cents
      payslips.sum(:gross_cents)
    end

    def total_net_cents
      payslips.sum(:net_cents)
    end

    def finalized?
      status == 'finalized'
    end

    def period_label
      "#{period_start.strftime('%b %d')} – #{period_end.strftime('%b %d, %Y')}"
    end

    private

    def period_end_after_start
      return if period_start.nil? || period_end.nil?

      errors.add(:period_end, 'must be after the start') if period_end < period_start
    end
  end
end
