# frozen_string_literal: true

module People
  # A batch of payslips for one pay period. Draft until finalized (totals
  # locked in) and paid once money goes out.
  class PayRun < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'pay_runs'

    # The stored totals and notes are encrypted at rest (#421), so totals are added up in Ruby.
    encrypts :total_gross_cents, :total_net_cents, :notes

    has_many :payslips, class_name: 'People::Payslip', dependent: :destroy, inverse_of: :pay_run

    validates :name, presence: true
    validates :period_start, :period_end, presence: true
    validate :period_end_after_start
    validate :no_overlapping_pay_run, on: :create

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

    # pluck decrypts each value; SQL SUM over the encrypted column would not.
    def total_gross_cents
      payslips.pluck(:gross_cents).sum(&:to_i)
    end

    def total_net_cents
      payslips.pluck(:net_cents).sum(&:to_i)
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

    # One pay run per day of work (#424): a second run over the same dates (a double-click, a retry, or a new run
    # for a week already paid) would pay the same approved hours twice. Off-cycle amounts go on the existing run
    # as manual payslips while it is a draft.
    def no_overlapping_pay_run
      return if period_start.nil? || period_end.nil? || period_end < period_start

      other = self.class.where('period_start <= ? AND period_end >= ?', period_end, period_start).order(:period_start).first
      return unless other

      errors.add(:base, "#{other.name} (#{other.period_label}) already covers some of these dates. Open that pay run instead.")
    end
  end
end
