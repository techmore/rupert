# frozen_string_literal: true

module People
  # Everything waiting for a decision from one reviewer, across corrections, time off, shift trades
  # and submitted timesheets. Each item knows what the viewer may do with it; items the viewer may
  # not decide (their own, another store's, no permission) are left out rather than shown read-only.
  class ApprovalInbox
    Item = Struct.new(:kind, :record, :employee, :title, :facts, :warnings, :requested_at, :requester, :path, keyword_init: true) do
      def key = "#{kind}-#{record.id}"
      def dom_id = "approval-#{key}"
    end

    KIND_LABELS = { 'correction' => 'Fix a punch', 'leave' => 'Time off', 'trade' => 'Shift trade', 'timesheet' => 'Timesheet' }.freeze

    attr_reader :user

    def initialize(user)
      @user = user
      @own_worker = TimeClockService.worker_for(user, include_on_leave: true)
    end

    def items
      @items ||= (corrections + leave + trades + timesheets).sort_by { |item| item.requested_at || Time.at(0) }
    end

    def count = items.size
    def by_kind = items.group_by(&:kind)

    def self.count_for(user)
      new(user).count
    rescue StandardError
      0
    end

    # Finds one item the viewer may decide, or nil.
    def find(kind, id)
      items.find { |item| item.kind == kind.to_s && item.record.id == id.to_i }
    end

    def can_review_corrections? = ClockCorrection.reviewer?(user)
    def can_review_leave? = user.can?('leave.write')
    def can_review_trades? = user.can?('schedule.write') || user.can?('hr.write')
    def can_review_timesheets? = user.can_review_timesheets?
    def any_permission? = can_review_corrections? || can_review_leave? || can_review_trades? || can_review_timesheets?

    private

    def covers?(employee)
      People::StoreScope.covers?(user, employee)
    end

    def own?(employee)
      employee && (employee.user_id == user.id || (@own_worker && @own_worker.id == employee.id))
    end

    def corrections
      return [] unless can_review_corrections?

      ClockCorrection.where(status: 'pending').includes(clock_shift: :employee).includes(:requester).filter_map do |correction|
        shift = correction.clock_shift
        employee = shift.employee
        next if own?(employee) || correction.requested_by_id == user.id || !covers?(employee)

        facts = ["#{shift.started_at.strftime('%a %b %-d')}: #{span(correction.original_started_at, correction.original_ended_at)} → #{span(correction.proposed_started_at, correction.proposed_ended_at)}",
                 "Hours #{format('%.2f', hours_between(correction.original_started_at, correction.original_ended_at))} → #{format('%.2f', hours_between(correction.proposed_started_at, correction.proposed_ended_at))}"]
        Item.new(kind: 'correction', record: correction, employee: employee, title: correction.reason.to_s.truncate(120), facts: facts, warnings: [],
          requested_at: correction.created_at, requester: correction.requester, path: Rails.application.routes.url_helpers.time_clock_path(anchor: "shift-#{shift.id}"))
      end
    end

    def leave
      return [] unless can_review_leave?

      People::LeaveRequest.pending.includes(:employee).filter_map do |request|
        employee = request.employee
        next if own?(employee) || !covers?(employee)

        balance = employee.leave_balances.find_by(leave_type: request.leave_type, year: request.starts_on.year)
        hours = request.hours.presence || request.days * 8
        facts = ["#{request.leave_type.humanize} · #{request.starts_on.strftime('%a %b %-d')}#{" – #{request.ends_on.strftime('%a %b %-d')}" if request.ends_on != request.starts_on} · #{format('%g', hours)} h"]
        warnings = []
        if balance && request.leave_type != 'unpaid'
          remaining = balance.remaining_hours
          facts << "#{format('%g', remaining)} h #{request.leave_type} left this year"
          warnings << "Over their balance by #{format('%g', hours - remaining)} h" if hours > remaining
        end
        if defined?(People::BlackoutDate) && People::BlackoutDate.overlapping(request.starts_on, request.ends_on).exists?
          warnings << 'Falls on a blackout date'
        end
        notice_days = TimeRules.for.time_off_min_notice_days
        warnings << "Less than #{notice_days} days notice" if notice_days.positive? && (request.starts_on - request.created_at.to_date).to_i < notice_days
        Item.new(kind: 'leave', record: request, employee: employee, title: request.reason.presence || "#{request.leave_type.humanize} request", facts: facts,
          warnings: warnings, requested_at: request.created_at, requester: employee.user, path: Rails.application.routes.url_helpers.people_leave_request_path(request))
      end
    end

    def trades
      return [] unless can_review_trades? && defined?(People::ShiftTradeWorkflow)

      People::ShiftTrade.pending_review.includes(:scheduled_shift, :from_employee, :to_employee, :requested_by).filter_map do |trade|
        shift = trade.scheduled_shift
        next if shift.nil? || own?(trade.from_employee) || own?(trade.to_employee) || !covers?(trade.to_employee || trade.from_employee)
        next unless People::StoreScope.manages?(user, shift.location_id)

        facts = ["#{trade.kind_label} · #{shift.starts_at.strftime('%a %b %-d')} · #{shift.time_label}"]
        facts << "#{trade.from_employee&.name || 'Open shift'} → #{trade.to_employee&.name || 'nobody yet'}"
        facts << "In exchange for #{trade.counter_shift.starts_at.strftime('%a %b %-d')} · #{trade.counter_shift.time_label}" if trade.counter_shift
        warnings = trade.checks.map { |check| check['message'] }
        Item.new(kind: 'trade', record: trade, employee: trade.to_employee || trade.from_employee, title: trade.note.presence || trade.kind_label, facts: facts,
          warnings: warnings, requested_at: trade.accepted_at || trade.created_at, requester: trade.requested_by,
          path: Rails.application.routes.url_helpers.people_scheduled_shifts_path(week: shift.starts_at.to_date.beginning_of_week.iso8601))
      end
    end

    def timesheets
      return [] unless can_review_timesheets?

      scope = People::TimesheetPolicy.visible_to(user).where(status: 'submitted').includes(:employee)
      scope.filter_map do |sheet|
        employee = sheet.employee
        next unless People::TimesheetPolicy.new(user, sheet).approve? && covers?(employee)

        summary = TimesheetInsights.summaries([sheet])[sheet.id]
        facts = ["#{sheet.period_label} · #{format('%.2f', summary.total)} h"]
        Item.new(kind: 'timesheet', record: sheet, employee: employee, title: "Timesheet for #{sheet.period_label}", facts: facts,
          warnings: summary.flags, requested_at: sheet.submitted_at || sheet.updated_at, requester: employee&.user,
          path: Rails.application.routes.url_helpers.people_timesheet_path(sheet))
      end
    end

    def span(from, to)
      return "#{from.strftime('%-l:%M %p')} – open" if to.nil?

      "#{from.strftime('%-l:%M %p')} – #{to.strftime('%-l:%M %p')}"
    end

    def hours_between(from, to)
      return 0 if from.nil? || to.nil?

      (to - from) / 3600.0
    end
  end
end
