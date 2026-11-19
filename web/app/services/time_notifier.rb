# frozen_string_literal: true

# Every time-and-pay event that reaches a person goes through here: one in-app Notification (the bell)
# plus a push to the person's devices (PushDeliveryJob; a no-op until APNs / Web Push is configured).
# Each method is named for the event so callers never compose titles themselves, and the person's
# notification preferences (User#wants_notification?) are honoured in one place.
#
# Kinds map to User::NOTIFICATION_KINDS: schedule_posted, schedule_changed, approvals, trade_offers,
# missed_clock_out, break_due, timesheet.
class TimeNotifier
  class << self
    def schedule_posted(users, week_start:, url:, shift_count: nil)
      Array(users).each do |user|
        send_to(user, kind: 'schedule_posted', title: "Your schedule for the week of #{week_start.strftime('%b %-d')} is posted",
          body: shift_count ? "#{shift_count} #{'shift'.pluralize(shift_count)} this week." : nil, url: url,
          dedupe_key: "schedule_posted:#{week_start.iso8601}:#{Time.current.to_i / 600}")
      end
    end

    def schedule_changed(user, shift:, url:, change: 'changed')
      send_to(user, kind: 'schedule_changed', title: "Your shift on #{shift.starts_at.strftime('%a %b %-d')} was #{change}",
        body: shift.respond_to?(:time_label) ? shift.time_label : nil, url: url, dedupe_key: "schedule_changed:#{shift.id}:#{shift.updated_at.to_i}")
    end

    def approval_needed(reviewers, what:, who:, url:, key:)
      Array(reviewers).each do |user|
        send_to(user, kind: 'approvals', title: "#{who} asks: #{what}", url: url, dedupe_key: "approval_needed:#{key}")
      end
    end

    def approval_decided(user, what:, approved:, url:, note: nil, key:)
      send_to(user, kind: 'approvals', title: "#{what}: #{approved ? 'approved' : 'denied'}", body: note.presence, url: url,
        dedupe_key: "approval_decided:#{key}")
    end

    def trade_offer(users, trade:, url:)
      Array(users).each do |user|
        send_to(user, kind: 'trade_offers', title: trade_title(trade), body: trade.note.presence, url: url, dedupe_key: "trade_offer:#{trade.id}:#{user.id}")
      end
    end

    def missed_clock_out(user, shift:, url:)
      send_to(user, kind: 'missed_clock_out', title: 'Did you forget to clock out?',
        body: "Your shift from #{shift.started_at.strftime('%-l:%M %p')} is still open. Fix it in a tap.", url: url,
        dedupe_key: "missed_clock_out:#{shift.id}")
    end

    def break_due(user, shift:, kind:, url:)
      label = kind.to_s == 'meal' ? 'meal break' : 'break'
      send_to(user, kind: 'break_due', title: "Time for your #{label}", body: 'Tap Break on the clock when you step away.', url: url,
        dedupe_key: "break_due:#{shift.id}:#{kind}")
    end

    def timesheet(user, title:, url:, body: nil, key:)
      send_to(user, kind: 'timesheet', title: title, body: body, url: url, dedupe_key: "timesheet:#{key}")
    end

    # Managers and shift leads who review for this store (or everyone with the permission when no store).
    def reviewers_for(permission, location_id: nil)
      User.where(tenant_id: Current.tenant_id).active.select { |u| u.can?(permission) && u.manages_location?(location_id) }
    end

    private

    def trade_title(trade)
      shift = trade.scheduled_shift
      when_label = "#{shift.starts_at.strftime('%a %b %-d')} · #{shift.time_label}"
      case trade.kind
      when 'give' then "Shift up for grabs: #{when_label}"
      when 'swap' then "Swap offered: #{when_label}"
      else "Open shift: #{when_label}"
      end
    end

    def send_to(user, kind:, title:, body: nil, url: nil, dedupe_key: nil)
      user = User.find_by(id: user) unless user.is_a?(User)
      return if user.nil? || !user.wants_notification?(kind)

      notification = Notification.deliver(user.id, kind: kind, title: title, body: body, url: url, dedupe_key: dedupe_key, actor: nil)
      return notification if notification.nil? || !notification.persisted?

      PushDeliveryJob.perform_later(notification.id) if PushDeliveryJob.enabled?
      notification
    end
  end
end
