# frozen_string_literal: true

module People
  # A change of hands for one planned shift.
  #
  #   kind 'give'   the owner offers the shift to anyone eligible (to_employee nil until someone takes it)
  #   kind 'swap'   the owner offers to exchange it for a specific colleague's shift (counter_shift)
  #   kind 'pickup' a worker claims an open shift (from_employee nil)
  #
  # Status: open (waiting for a taker) → accepted (taker found; waiting for a manager when the
  # location requires approval) → approved (shift moved) / denied / cancelled / expired.
  # Guardrails (TimeRules#trade_checks) run when someone accepts and again at approval; the result
  # is kept in checks_json so the manager sees what was checked.
  class ShiftTrade < ApplicationRecord
    include TenantScoped

    self.table_name = 'shift_trades'

    KINDS = %w[give swap pickup].freeze
    STATUSES = %w[open accepted approved denied cancelled expired].freeze
    LABELS = { 'give' => 'Give away', 'swap' => 'Swap', 'pickup' => 'Pick up' }.freeze

    belongs_to :scheduled_shift, class_name: 'People::ScheduledShift'
    belongs_to :counter_shift, class_name: 'People::ScheduledShift', optional: true
    belongs_to :from_employee, class_name: 'People::Employee', optional: true
    belongs_to :to_employee, class_name: 'People::Employee', optional: true
    belongs_to :requested_by, class_name: 'User', optional: true
    belongs_to :reviewed_by, class_name: 'User', optional: true

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }
    validates :note, :review_note, length: { maximum: 1000 }
    validate :one_live_trade_per_shift, on: :create

    scope :live, -> { where(status: %w[open accepted]) }
    scope :pending_review, -> { where(status: 'accepted') }
    scope :recent, -> { order(created_at: :desc) }

    def kind_label = LABELS.fetch(kind, kind)
    def live? = %w[open accepted].include?(status)

    def checks
      checks_json.present? ? JSON.parse(checks_json) : []
    rescue JSON::ParserError
      []
    end

    def blocking_checks = checks.select { |c| c['level'] == 'block' }
    def warning_checks = checks.select { |c| c['level'] == 'warn' }

    private

    def one_live_trade_per_shift
      return if scheduled_shift_id.blank?

      errors.add(:base, 'This shift already has an open trade') if self.class.live.where(scheduled_shift_id: scheduled_shift_id).exists?
    end
  end
end
