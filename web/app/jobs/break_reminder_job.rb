# frozen_string_literal: true

# Nudges staff to take their break or meal (TimeNotifier.break_due) once the store's thresholds pass
# (TimeRules meal_break_after_hours / rest_break_every_hours) and the reminder is turned on. One
# reminder per shift and kind (Notification dedupe_key); it never clocks anyone out or in.
class BreakReminderJob < ApplicationJob
  queue_as :default

  def perform
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) { BusinessClock.use(tenant: tenant) { remind_tenant } }
    rescue StandardError => e
      logger.error("#{self.class}: break reminders failed for tenant #{tenant.id}: #{e.class}")
    end
  end

  # Which reminders a shift is due for right now: 'meal' once the meal threshold has passed without a
  # meal, 'rest' once the rest interval has passed since the clock-in or the last break.
  def self.due_kinds(shift, rules: TimeRules.for(shift.location_id), at: Time.current)
    return [] unless rules.break_reminders? && shift.ended_at.nil? && !shift.stale_open?(at)

    worked_hours = shift.hours(at: at)
    kinds = []
    if rules.meal_break_after_hours&.positive? && worked_hours >= rules.meal_break_after_hours.to_f && shift.breaks.none? { |b| b.kind == 'meal' }
      kinds << 'meal'
    end
    if rules.rest_break_every_hours&.positive? && !shift.on_break?
      last_break_end = shift.breaks.filter_map(&:ended_at).max || shift.started_at
      kinds << 'rest' if (at - last_break_end) / 3600.0 >= rules.rest_break_every_hours.to_f
    end
    kinds
  end

  private

  def remind_tenant
    url = Rails.application.routes.url_helpers.employee_app_path
    ClockShift.open.includes(:breaks, :user).find_each do |shift|
      next unless shift.user

      self.class.due_kinds(shift).each { |kind| TimeNotifier.break_due(shift.user, shift: shift, kind: kind, url: url) }
    end
  end
end
