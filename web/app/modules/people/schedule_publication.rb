# frozen_string_literal: true

module People
  # A record of a week's schedule being posted to staff (who, when, how many shifts). Predictive
  # scheduling rules read the first publication of a week to know how much notice staff had.
  class SchedulePublication < ApplicationRecord
    include TenantScoped

    self.table_name = 'schedule_publications'

    belongs_to :location, optional: true
    belongs_to :published_by, class_name: 'User', optional: true

    validates :week_start, :published_at, presence: true

    scope :for_week, ->(week_start, location_id = nil) { where(week_start: week_start).where(location_id: [location_id.presence, nil].uniq) }

    def self.first_for(week_start, location_id = nil)
      for_week(week_start, location_id).order(:published_at).first
    end
  end
end
