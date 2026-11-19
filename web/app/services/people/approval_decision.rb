# frozen_string_literal: true

module People
  # Applies one Approve / Deny from the approvals inbox through the workflow that owns the record,
  # then tells the person who asked (TimeNotifier). Raises Error with a sentence a manager can read.
  class ApprovalDecision
    class Error < StandardError; end

    def self.call(item, reviewer:, approve:, note: nil)
      new(item, reviewer: reviewer, approve: approve, note: note.to_s.strip.presence).call
    end

    def initialize(item, reviewer:, approve:, note:)
      @item = item
      @reviewer = reviewer
      @approve = approve
      @note = note
    end

    def call
      case @item.kind
      when 'correction' then decide_correction
      when 'leave' then decide_leave
      when 'trade' then decide_trade
      when 'timesheet' then decide_timesheet
      else raise Error, 'Unknown approval item.'
      end
      notify
      @item
    rescue TimeClockService::Error, TimesheetWorkflow::Error, AASM::InvalidTransition => e
      raise Error, e.message
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.to_sentence
    end

    private

    def decide_correction
      correction = @item.record
      TimeClockService.review(correction: correction, reviewer: @reviewer, approve: @approve)
      correction.update_columns(review_note: @note, updated_at: Time.current) if @note
    end

    def decide_leave
      changed = LeaveRequestWorkflow.change(@item.record, @approve ? :approve : :deny, note: @note, notify: false)
      raise Error, 'This request was already decided.' unless changed
    end

    def decide_trade
      raise Error, 'Shift trades are not available yet.' unless defined?(People::ShiftTradeWorkflow)

      People::ShiftTradeWorkflow.review(@item.record, reviewer: @reviewer, approve: @approve, note: @note)
    end

    def decide_timesheet
      raise Error, 'Say what to fix when returning a timesheet.' if !@approve && @note.blank?

      TimesheetWorkflow.new(user: @reviewer).change(@item.record, @approve ? :approve : :reject, review_note: @note)
    end

    def notify
      user = @item.requester || @item.employee&.user
      return if user.nil? || user.id == @reviewer.id

      what = case @item.kind
             when 'correction' then "Your punch fix for #{@item.record.clock_shift.started_at.strftime('%a %b %-d')}"
             when 'leave' then "Time off #{@item.record.starts_on.strftime('%b %-d')}#{" – #{@item.record.ends_on.strftime('%b %-d')}" if @item.record.ends_on != @item.record.starts_on}"
             when 'trade' then "Your #{@item.record.kind_label.downcase} for #{@item.record.scheduled_shift.starts_at.strftime('%a %b %-d')}"
             else "Your timesheet for #{@item.record.period_label}"
             end
      TimeNotifier.approval_decided(user, what: what, approved: @approve, url: employee_url_for(@item), note: @note, key: "#{@item.kind}:#{@item.record.id}:#{@approve ? 'approved' : 'denied'}")
    end

    def employee_url_for(item)
      helpers = Rails.application.routes.url_helpers
      case item.kind
      when 'correction' then helpers.time_clock_path
      when 'leave' then helpers.employee_time_off_path
      when 'trade' then helpers.employee_schedule_path
      else helpers.people_timesheet_path(item.record)
      end
    end
  end
end
