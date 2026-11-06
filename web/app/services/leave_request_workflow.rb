# frozen_string_literal: true

# Serialize decisions and balance changes together. Repeated review/cancel
# requests cannot consume or restore the same allowance twice.
#
# note:   the reviewer's sentence to the staff member (stored in review_note).
# notify: tell the staff member through TimeNotifier (the approvals inbox notifies itself).
class LeaveRequestWorkflow
  def self.change(request, event, self_service: false, note: nil, notify: true)
    changed = People::LeaveRequest.transaction do
      Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
      request.reload
      raise ActiveRecord::RecordNotFound unless request.tenant_id == Current.tenant_id
      if self_service
        worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
        raise Pundit::NotAuthorizedError unless event == :cancel && worker && request.employee_id == worker.id
        next false unless request.requested?
      else
        raise Pundit::NotAuthorizedError unless Current.user&.active? && Current.user.can?('leave.write')
        raise Pundit::NotAuthorizedError if event.in?(%i[approve deny]) && request.employee&.user_id == Current.user.id
      end
      next false unless request.public_send("may_#{event}?")

      approved_before = request.approved?
      request.public_send("#{event}!")
      if event.in?(%i[approve deny])
        request.update!(reviewed_by: Current.user.id, reviewed_at: Time.current, review_note: note.to_s.strip.presence)
      end
      if request.leave_type != 'unpaid' && (event == :approve || (event == :cancel && approved_before))
        balance = request.employee.leave_balances.find_or_initialize_by(leave_type: request.leave_type, year: request.starts_on.year)
        hours = request.hours.presence || request.days * 8
        balance.used_hours = event == :approve ? balance.used_hours + hours : [balance.used_hours - hours, 0].max
        balance.save!
      end
      ActivityLogger.log("leave_#{event == :approve ? 'approved' : event == :deny ? 'denied' : 'cancelled'}", subject: request)
      true
    end
    notify_decision(request, event, note) if changed && notify && event.in?(%i[approve deny]) && !self_service
    changed
  end

  def self.notify_decision(request, event, note)
    user = request.employee&.user
    return if user.nil?

    label = "Time off #{request.starts_on.strftime('%b %-d')}#{" – #{request.ends_on.strftime('%b %-d')}" if request.ends_on != request.starts_on}"
    TimeNotifier.approval_decided(user, what: label, approved: event == :approve, url: Rails.application.routes.url_helpers.employee_time_off_path,
      note: note, key: "leave:#{request.id}:#{event}")
  end
end
