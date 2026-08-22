# frozen_string_literal: true

module Goals
  class Goal < ApplicationRecord
    include TenantScoped
    include AASM

    self.table_name = 'goals'

    validates :name, presence: true
    validates :target_value, numericality: true, allow_nil: true
    validates :current_value, numericality: true, allow_nil: true

    scope :recent, ->(limit = 20) { order(updated_at: :desc).limit(limit) }
    scope :active, -> { where(status: 'active') }

    aasm column: 'status', no_direct_assignment: true do
      state :draft, initial: true
      state :active
      state :achieved
      state :abandoned

      event :activate do
        transitions from: :draft, to: :active
      end
      event :achieve do
        transitions from: %i[active draft], to: :achieved
      end
      event :abandon do
        transitions from: %i[draft active], to: :abandoned
      end
    end

    def progress_pct
      return if target_value.to_f.zero?

      (current_value.to_f / target_value.to_f * 100).round.clamp(0, 100)
    end
  end
end
