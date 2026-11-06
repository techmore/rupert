# frozen_string_literal: true

module People
  # Dates when time off is not granted (holiday rush, inventory). Staff see them before they ask;
  # a request inside a blackout is still allowed but flagged for the manager.
  class BlackoutDate < ApplicationRecord
    include TenantScoped

    self.table_name = 'blackout_dates'

    belongs_to :location, optional: true
    belongs_to :created_by, class_name: 'User', optional: true

    validates :starts_on, :ends_on, presence: true
    validates :reason, presence: true, length: { maximum: 120 }
    validate { errors.add(:ends_on, 'must be after the start') if starts_on && ends_on && ends_on < starts_on }

    scope :upcoming, -> { where('ends_on >= ?', Date.current).order(:starts_on) }
    scope :overlapping, ->(from, to) { where('starts_on <= ? AND ends_on >= ?', to, from) }

    def label
      starts_on == ends_on ? starts_on.strftime('%b %-d') : "#{starts_on.strftime('%b %-d')} – #{ends_on.strftime('%b %-d')}"
    end
  end
end
