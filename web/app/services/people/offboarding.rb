# frozen_string_literal: true

module People
  # What happens to a worker's time & pay records when they are terminated (docs/time-and-pay/DECISIONS.md):
  # app sessions and setup links are revoked, the clock PIN is cleared, future planned shifts become
  # open shifts, live trades are cancelled. An open punch is left for a manager to fix through a
  # correction (never closed silently) and shows up as a missed-punch exception.
  class Offboarding
    Result = Struct.new(:sessions_revoked, :links_revoked, :shifts_opened, :trades_cancelled, :open_shift, keyword_init: true)

    def self.call(employee, actor: Current.user)
      new(employee, actor: actor).call
    end

    def initialize(employee, actor:)
      @employee = employee
      @actor = actor
    end

    def call
      result = Result.new(sessions_revoked: 0, links_revoked: 0, shifts_opened: 0, trades_cancelled: 0)
      People::Employee.transaction do
        result.sessions_revoked = EmployeeAppSession.where(employee_id: @employee.id, revoked_at: nil).update_all(revoked_at: Time.current)
        result.links_revoked = EmployeeAccessGrant.where(employee_id: @employee.id, used_at: nil).where('expires_at > ?', Time.current).update_all(expires_at: Time.current)
        PushDevice.disable_all_for(@employee.user, 'staff member left') if @employee.user_id
        @employee.update_columns(pin_digest: nil, pin_set_at: nil, pin_failed_count: 0, pin_locked_until: nil, updated_at: Time.current)
        People::ScheduledShift.live.where(employee_id: @employee.id).where('starts_at > ?', Time.current).find_each do |shift|
          shift.update_columns(employee_id: nil, notes: [shift.notes.presence, "Opened when #{@employee.name} left"].compact.join("\n"), last_changed_at: Time.current, updated_at: Time.current)
          result.shifts_opened += 1
        end
        People::ShiftTrade.live.where('from_employee_id = ? OR to_employee_id = ?', @employee.id, @employee.id).find_each do |trade|
          trade.update!(status: 'cancelled', review_note: "Cancelled: #{@employee.name} left", reviewed_at: Time.current)
          result.trades_cancelled += 1
        end
        result.open_shift = ClockShift.open.find_by(employee_id: @employee.id)
      end
      ActivityLogger.log('employee_offboarded', subject: @employee, actor: @actor,
        details: "sessions #{result.sessions_revoked}, links #{result.links_revoked}, shifts opened #{result.shifts_opened}, trades cancelled #{result.trades_cancelled}#{', open punch left for review' if result.open_shift}")
      result
    end
  end
end
