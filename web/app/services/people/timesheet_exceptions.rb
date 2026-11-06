# frozen_string_literal: true

module People
  # What a reviewer must look at before a period's hours are safe to approve: missed punches,
  # overtime, missed meals, corrections waiting, shifts not yet on a sheet, sheets waiting.
  # Read-only; every item carries the one fix. Scoped to the staff a reviewer may see.
  class TimesheetExceptions
    Item = Struct.new(:kind, :employee, :title, :detail, :level, :record, :timesheet, :date, keyword_init: true) do
      def key = "#{kind}:#{record.class.name}:#{record&.id}"
      def blocking? = level == 'block'
    end

    KIND_LABELS = {
      'missed_punch' => 'Never clocked out', 'overtime' => 'Overtime', 'daily_overtime' => 'Daily overtime',
      'missed_meal' => 'No meal break', 'correction' => 'Correction waiting', 'unimported' => 'Shifts not on timesheet',
      'submitted' => 'Timesheet in review', 'rejected' => 'Returned, not fixed'
    }.freeze

    attr_reader :from, :to, :employees

    # employees: the People::Employee scope the reviewer may see (already store-scoped).
    def initialize(from:, to:, employees:, rules: PayRules.current)
      @from = from
      @to = to
      @employees = employees
      @rules = rules
      @employee_by_id = employees.index_by(&:id)
    end

    def items
      @items ||= (missed_punches + corrections + overtime + missed_meals + unimported + sheets_waiting)
                 .sort_by { |item| [item.blocking? ? 0 : 1, item.employee&.name.to_s, item.date || Date.new(1970)] }
    end

    def by_employee = items.group_by { |item| item.employee&.id }
    def count = items.size
    def blocking_count = items.count(&:blocking?)

    # Employee ids with any blocking exception (their sheets are not bulk-approvable).
    def blocked_employee_ids
      items.select(&:blocking?).filter_map { |item| item.employee&.id }.to_set
    end

    # Timesheet ids that carry an exception (blocking or not) inside the range.
    def flagged_timesheet_ids
      items.filter_map { |item| item.timesheet&.id }.to_set
    end

    private

    def window
      from.in_time_zone...(to + 1).in_time_zone
    end

    def shifts
      @shifts ||= ClockShift.where(employee_id: @employee_by_id.keys).where(started_at: window).includes(:breaks, :location).order(:started_at).to_a
    end

    def sheets
      @sheets ||= People::Timesheet.where(employee_id: @employee_by_id.keys).where('period_start <= ? AND period_end >= ?', to, from).includes(:employee).to_a
    end

    def sheet_for(employee_id, date)
      sheets.find { |sheet| sheet.employee_id == employee_id && (sheet.period_start..sheet.period_end).cover?(date) }
    end

    def missed_punches
      ClockShift.stale_open.where(employee_id: @employee_by_id.keys).includes(:corrections).map do |shift|
        pending = shift.corrections.any? { |c| c.status == 'pending' }
        next if pending

        Item.new(kind: 'missed_punch', employee: @employee_by_id[shift.employee_id], record: shift, level: 'block',
          title: KIND_LABELS['missed_punch'], date: shift.started_at.to_date,
          detail: "Clocked in #{shift.started_at.strftime('%a %b %-d, %-l:%M %p')} and never clocked out.",
          timesheet: sheet_for(shift.employee_id, shift.started_at.to_date))
      end.compact
    end

    def corrections
      ClockCorrection.where(status: 'pending').joins(:clock_shift).where(clock_shifts: { employee_id: @employee_by_id.keys })
                     .includes(:clock_shift, :requester).map do |correction|
        shift = correction.clock_shift
        Item.new(kind: 'correction', employee: @employee_by_id[shift.employee_id], record: correction, level: 'block',
          title: KIND_LABELS['correction'], date: shift.started_at.to_date,
          detail: "#{correction.reason.to_s.truncate(80)} · asked by #{correction.requester&.display_name || 'the worker'}",
          timesheet: sheet_for(shift.employee_id, shift.started_at.to_date))
      end
    end

    # Weekly overtime per work week (PayRules) and daily overtime (TimeRules) from closed punches.
    def overtime
      items = []
      shifts.select(&:closed?).group_by(&:employee_id).each do |employee_id, rows|
        rows.group_by { |s| @rules.week_start(s.started_at.to_date) }.each do |week_start, week_rows|
          hours = week_rows.sum(&:paid_hours)
          over = @rules.hours_over_threshold(hours)
          next unless over.positive?

          items << Item.new(kind: 'overtime', employee: @employee_by_id[employee_id], record: week_rows.first, level: 'warn',
            title: KIND_LABELS['overtime'], date: week_start,
            detail: "#{format('%.2f', hours)} h clocked in the week of #{week_start.strftime('%b %-d')}: #{format('%.2f', over)} h over #{@rules.overtime_threshold_label}" \
                    "#{@rules.overtime_enabled? ? '' : ' (overtime pay is off; check the timesheet)'}",
            timesheet: sheet_for(employee_id, week_start))
        end
        rows.each do |shift|
          daily = TimeRules.for(shift.location_id)
          next unless daily.daily_overtime? && shift.paid_hours > daily.daily_overtime_threshold_hours.to_f

          items << Item.new(kind: 'daily_overtime', employee: @employee_by_id[employee_id], record: shift, level: 'warn',
            title: KIND_LABELS['daily_overtime'], date: shift.started_at.to_date,
            detail: "#{format('%.2f', shift.paid_hours)} h on #{shift.started_at.strftime('%a %b %-d')}, over #{daily.daily_overtime_threshold_hours.to_s('F')} h a day",
            timesheet: sheet_for(employee_id, shift.started_at.to_date))
        end
      end
      items
    end

    def missed_meals
      shifts.select(&:closed?).filter_map do |shift|
        rules = TimeRules.for(shift.location_id)
        threshold = rules.meal_break_after_hours
        next if threshold.nil? || !threshold.positive?
        next unless shift.hours > threshold.to_f
        next if shift.breaks.any? { |b| b.kind == 'meal' }

        Item.new(kind: 'missed_meal', employee: @employee_by_id[shift.employee_id], record: shift, level: 'warn',
          title: KIND_LABELS['missed_meal'], date: shift.started_at.to_date,
          detail: "#{format('%.1f', shift.hours)} h on #{shift.started_at.strftime('%a %b %-d')} with no meal recorded (rule: after #{threshold.to_s('F')} h).",
          timesheet: sheet_for(shift.employee_id, shift.started_at.to_date))
      end
    end

    def unimported
      sheets.select(&:draft?).filter_map do |sheet|
        count = sheet.unimported_shift_count
        next unless count.positive?

        Item.new(kind: 'unimported', employee: sheet.employee, record: sheet, timesheet: sheet, level: 'warn',
          title: KIND_LABELS['unimported'], date: sheet.period_start,
          detail: "#{count} finished #{'shift'.pluralize(count)} not on the #{sheet.period_label} timesheet yet.")
      end
    end

    def sheets_waiting
      sheets.select { |s| s.submitted? || s.rejected? }.map do |sheet|
        Item.new(kind: sheet.submitted? ? 'submitted' : 'rejected', employee: sheet.employee, record: sheet, timesheet: sheet, level: 'info',
          title: KIND_LABELS[sheet.submitted? ? 'submitted' : 'rejected'], date: sheet.period_start,
          detail: sheet.submitted? ? "Sent #{sheet.submitted_at ? ActionController::Base.helpers.time_ago_in_words(sheet.submitted_at) + ' ago' : 'for review'} · #{sheet.period_label}" : "Returned with: #{sheet.review_note.to_s.truncate(80)}")
      end
    end
  end
end
