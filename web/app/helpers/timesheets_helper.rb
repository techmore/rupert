# frozen_string_literal: true

# One vocabulary for time records, shared by the staff and reviewer screens (docs/ui-standards.md §5,
# "Timesheets"). Status words, hours, times and periods are written here once, so the two sides of the
# product read the same.
module TimesheetsHelper
  # Status word and pill per timesheet state. `submitted` reads "In review" (guidelines §7) and
  # `rejected` reads "Returned", matching the "Return for correction" action.
  TIMESHEET_STATUSES = {
    'draft' => ['Draft', 'pill-taupe'],
    'submitted' => ['In review', 'pill-clay'],
    'approved' => ['Approved', 'pill-fern'],
    'rejected' => ['Returned', 'pill-rose']
  }.freeze

  EVENT_SENTENCES = {
    'created' => 'Started the timesheet',
    'update' => 'Edited the period or notes',
    'add_entry' => 'Added hours',
    'update_entry' => 'Edited hours',
    'remove_entry' => 'Removed hours',
    'import_shifts' => 'Imported clock shifts',
    'submit' => 'Submitted for review',
    'approve' => 'Approved',
    'reject' => 'Returned for correction',
    'reopen' => 'Reopened for editing'
  }.freeze

  def timesheet_status_label(status)
    TIMESHEET_STATUSES.fetch(status.to_s, [status.to_s.humanize]).first
  end

  def timesheet_status_pill(sheet_or_status)
    status = sheet_or_status.respond_to?(:status) ? sheet_or_status.status : sheet_or_status
    label, pill = TIMESHEET_STATUSES.fetch(status.to_s, [status.to_s.humanize, 'pill-taupe'])
    tag.span(label, class: pill, data: { timesheet_status: status })
  end

  # Hours to two decimals everywhere, so a total always equals the sum of the days shown.
  # `unit: true` adds " h" for prose; zero or nil read as an en dash when `blank_zero` is set.
  def format_hours(value, unit: false, blank_zero: false)
    return '–' if blank_zero && (value.nil? || value.to_d.zero?)

    text = number_with_precision(value.to_d, precision: 2, delimiter: ',')
    unit ? "#{text} h" : text
  end

  # "Oct 22 – 28, 2026"; months and years are written only where they differ.
  def period_range(from, to)
    People::Timesheet.range_label(from, to)
  end

  # "Oct 22, 2026, 9:00 AM" in the business time zone.
  def timesheet_time(time)
    return '' unless time

    time.in_time_zone.strftime('%b %-d, %Y, %-I:%M %p')
  end

  # "9:00 AM – 4:30 PM"; an overnight shift names the end date; an open shift says so.
  def shift_span(started_at, ended_at)
    start = started_at.in_time_zone
    return "#{start.strftime('%-I:%M %p')} – still clocked in" unless ended_at

    finish = ended_at.in_time_zone
    finish_text = finish.to_date == start.to_date ? finish.strftime('%-I:%M %p') : finish.strftime('%b %-d, %-I:%M %p')
    "#{start.strftime('%-I:%M %p')} – #{finish_text}"
  end

  def timesheet_event_sentence(event)
    sentence = EVENT_SENTENCES.fetch(event.action.to_s, event.action.to_s.humanize)
    details = event.details.is_a?(Hash) ? event.details : {}
    note = details['review_note'].presence
    note ? "#{sentence}: “#{note}”" : sentence
  end

  # One sentence under the header: the state, who acted, and the one next step for this viewer.
  def timesheet_state_note(sheet, viewer: Current.user)
    own = sheet.employee&.user_id == viewer&.id
    reviewer = sheet.reviewer&.display_name || 'a reviewer'
    case sheet.status
    when 'draft'
      own ? 'Not sent yet. Check your days, then submit the week for review.' : 'Not submitted yet. The staff member submits it when the week is done.'
    when 'submitted'
      sent = sheet.submitted_at ? " on #{timesheet_time(sheet.submitted_at)}" : ''
      own ? "Sent for review#{sent}. It is locked until a reviewer approves or returns it." : "Submitted#{sent}. Check each day against the clock times, then approve or return it."
    when 'approved'
      locked = sheet.payroll_locked? ? ' It is included in payroll.' : ''
      "Approved by #{reviewer}#{" on #{timesheet_time(sheet.reviewed_at)}" if sheet.reviewed_at}.#{locked}"
    when 'rejected'
      own ? "Returned by #{reviewer}. Reopen it, fix what the comment asks, then submit it again." : "Returned to the staff member by #{reviewer}. It comes back here when they submit it again."
    else
      ''
    end
  end
end
