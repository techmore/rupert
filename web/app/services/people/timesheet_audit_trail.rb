# frozen_string_literal: true

module People
  # One chronological history for a timesheet: its workflow events plus every correction to the clock
  # shifts in its period (original and edited times, who asked, who decided, why). Read-only.
  class TimesheetAuditTrail
    Line = Struct.new(:at, :actor, :sentence, :detail, :kind, keyword_init: true)

    def self.for(timesheet)
      new(timesheet).lines
    end

    def initialize(timesheet)
      @timesheet = timesheet
    end

    def lines
      (event_lines + correction_lines).sort_by { |line| [line.at || Time.at(0), line.kind == 'event' ? 1 : 0] }
    end

    private

    def helpers
      @helpers ||= Object.new.extend(TimesheetsHelper)
    end

    def event_lines
      @timesheet.events.includes(:user).order(:id).map do |event|
        Line.new(at: event.created_at, actor: event.user&.display_name || 'Former account', sentence: helpers.timesheet_event_sentence(event), kind: 'event')
      end
    end

    def correction_lines
      from = @timesheet.period_start.in_time_zone
      to = (@timesheet.period_end + 1).in_time_zone
      corrections = ClockCorrection.joins(:clock_shift).where(clock_shifts: { employee_id: @timesheet.employee_id })
                                   .where('clock_shifts.started_at < ? AND clock_shifts.started_at >= ?', to, from)
                                   .includes(:requester, :reviewer, :clock_shift).order(:created_at)
      corrections.flat_map do |correction|
        day = correction.clock_shift.started_at.strftime('%a %b %-d')
        change = "#{helpers.shift_span(correction.original_started_at, correction.original_ended_at)} → #{helpers.shift_span(correction.proposed_started_at, correction.proposed_ended_at)}"
        lines = [Line.new(at: correction.created_at, actor: correction.requester&.display_name || 'the worker', kind: 'correction',
          sentence: "Asked to fix the punch on #{day}", detail: "#{change} · “#{correction.reason}”")]
        if correction.status != 'pending'
          lines << Line.new(at: correction.reviewed_at || correction.updated_at, actor: correction.reviewer&.display_name || 'a reviewer', kind: 'correction',
            sentence: "#{correction.status == 'approved' ? 'Approved' : 'Denied'} the punch fix on #{day}",
            detail: [correction.status == 'approved' ? "Shift now #{helpers.shift_span(correction.proposed_started_at, correction.proposed_ended_at)}; original #{helpers.shift_span(correction.original_started_at, correction.original_ended_at)} kept on record" : 'Shift unchanged',
                     correction.review_note.presence && "“#{correction.review_note}”"].compact.join(' · '))
        end
        lines
      end
    end
  end
end
