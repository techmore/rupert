# frozen_string_literal: true

module People
  # Posting a week to staff. Unpublished (draft) shifts are invisible to employees; publishing stamps
  # them, records a SchedulePublication and tells every affected worker. Later changes to a posted
  # shift tell its worker individually (`changed`, `cancelled`).
  class SchedulePublisher
    Result = Struct.new(:published, :workers, :notice_days, :short_notice?, keyword_init: true)

    def self.publish_week!(week_start, location_id: nil, by: Current.user)
      scope = People::ScheduledShift.between(week_start, week_start + 6).live.unpublished.for_location(location_id).includes(:employee)
      shifts = scope.to_a
      now = Time.current
      People::ScheduledShift.transaction do
        People::ScheduledShift.where(id: shifts.map(&:id)).update_all(published_at: now, updated_at: now)
        People::SchedulePublication.create!(location_id: location_id.presence, week_start: week_start, published_at: now, published_by: by,
          shift_count: shifts.size)
      end
      workers = shifts.filter_map(&:employee).uniq
      rules = TimeRules.for(location_id)
      notice_days = (week_start - Date.current).to_i
      url = Rails.application.routes.url_helpers.employee_schedule_path(week: week_start.iso8601)
      workers.each do |worker|
        next if worker.user.nil?

        count = shifts.count { |s| s.employee_id == worker.id }
        TimeNotifier.schedule_posted(worker.user, week_start: week_start, url: url, shift_count: count)
      end
      ActivityLogger.log('schedule_published', details: "Week of #{week_start.strftime('%b %-d, %Y')}: #{shifts.size} shifts", actor: by)
      Result.new(published: shifts, workers: workers, notice_days: notice_days,
        short_notice?: rules.schedule_notice_days.positive? && notice_days < rules.schedule_notice_days)
    end

    # Tell the worker about a change to an already-posted shift. `change` is 'changed' or 'cancelled'.
    def self.notify_change(shift, change:, previous_employee: nil)
      return unless shift.published?

      url = Rails.application.routes.url_helpers.employee_schedule_path(week: shift.starts_at.to_date.beginning_of_week.iso8601)
      [shift.employee, previous_employee].compact.uniq.each do |employee|
        next if employee.user.nil?

        label = previous_employee && employee == previous_employee && employee != shift.employee ? 'reassigned' : change
        TimeNotifier.schedule_changed(employee.user, shift: shift, url: url, change: label)
      end
    end
  end
end
