# frozen_string_literal: true

# Shared words and pills for items of the shared work-item table (#407), whatever their kind: the calendar (#417)
# and the marketing event screens (#415).
module WorkItemsHelper
  WORK_STATUS_LABELS = {
    'todo' => 'To do', 'in_progress' => 'In progress', 'blocked' => 'Blocked', 'done' => 'Done', 'planned' => 'Planned',
    'confirmed' => 'Confirmed', 'held' => 'Held', 'cancelled' => 'Cancelled'
  }.freeze

  WORK_STATUS_PILLS = {
    'done' => 'pill-fern', 'held' => 'pill-fern', 'in_progress' => 'pill-olive', 'confirmed' => 'pill-olive', 'blocked' => 'pill-rose'
  }.freeze

  WORK_EVENT_LABELS = {
    'confirm' => 'Confirm', 'hold' => 'Mark held', 'cancel' => 'Cancel event', 'reopen' => 'Reopen', 'start' => 'Start', 'finish' => 'Done'
  }.freeze

  def work_status_label(status) = WORK_STATUS_LABELS.fetch(status.to_s) { status.to_s.humanize }

  def work_status_pill(status, overdue: false)
    return tag.span('Overdue', class: 'pill-rose') if overdue

    tag.span(work_status_label(status), class: WORK_STATUS_PILLS.fetch(status.to_s, 'pill-taupe'))
  end

  def work_event_label(event) = WORK_EVENT_LABELS.fetch(event.to_s) { event.to_s.humanize }

  # "Oct 21, 2026, 3:40 PM – 5:00 PM EDT", in the event's own time zone.
  def event_when(item)
    starts = Marketing::WorkKinds.local_time(item, 'starts_at')
    ends = Marketing::WorkKinds.local_time(item, 'ends_at')
    return 'Not scheduled' unless starts

    first = "#{starts.strftime('%b %-d, %Y')}, #{starts.strftime('%-l:%M %p')}"
    return "#{first} #{starts.strftime('%Z')}" unless ends

    last = ends.to_date == starts.to_date ? ends.strftime('%-l:%M %p') : "#{ends.strftime('%b %-d, %Y')}, #{ends.strftime('%-l:%M %p')}"
    "#{first} – #{last} #{ends.strftime('%Z')}"
  end

  def event_place(item, locations = {})
    details = item.details
    [details['venue'].presence, locations[details['location_id']], Marketing::WorkKinds::CHANNELS[details['channel']]].compact.uniq.join(' · ').presence
  end

  # $1,234.56 for dollars; other currencies name their code (1,234.56 EUR).
  def result_money(cents, currency)
    amount = number_with_delimiter(format('%.2f', cents.to_i / 100.0))
    currency.to_s == 'USD' ? "$#{amount}" : "#{amount} #{currency}"
  end
end
