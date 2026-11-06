# frozen_string_literal: true

module Api
  module V1
    # The worker's own time-off requests and balances.
    class EmployeeLeaveRequestsController < EmployeeBaseController
      def index
        requests = worker.leave_requests.order(starts_on: :desc).limit(100)
        balances = People::LeaveRequest::LEAVE_TYPES.reject { |t| t == 'unpaid' }.map { |type| worker.leave_balance(type, Date.current.year) }
        render json: { data: requests.map { |r| request_json(r) },
                       balances: balances.map { |b| { leave_type: b.leave_type, year: b.year, accrued_hours: b.accrued_hours.to_f, used_hours: b.used_hours.to_f, remaining_hours: b.remaining_hours.to_f } },
                       blackout_dates: People::BlackoutDate.upcoming.select { |b| b.location_id.nil? || worker.works_at?(b.location_id) }.map { |b| { starts_on: b.starts_on, ends_on: b.ends_on, reason: b.reason } } }
      end

      # POST { leave_request: { leave_type, starts_on, ends_on, hours, reason, request_key } }
      def create
        values = params.require(:leave_request).permit(:leave_type, :starts_on, :ends_on, :hours, :reason, :request_key)
        if values[:request_key].present? && (existing = worker.leave_requests.find_by(request_key: values[:request_key]))
          return render json: { data: request_json(existing) }, status: :ok
        end

        request = worker.leave_requests.new(values)
        if request.hours.blank? && request.leave_type != 'unpaid' && request.starts_on && request.ends_on
          planned = worker.scheduled_shifts.live.between(request.starts_on, request.ends_on).sum(&:paid_hours)
          request.hours = planned.positive? ? planned.round(2) : (request.starts_on..request.ends_on).count { |d| !d.saturday? && !d.sunday? } * 8
        end
        request.save!
        ActivityLogger.log('leave_requested', subject: request, details: 'Staff app request; awaiting manager review.')
        TimeNotifier.approval_needed(TimeNotifier.reviewers_for('leave.write', location_id: worker.location_ids.first),
          what: "time off #{request.starts_on.strftime('%b %-d')} (#{request.leave_type})", who: worker.name,
          url: Rails.application.routes.url_helpers.people_leave_request_path(request), key: "leave:#{request.id}")
        render json: { data: request_json(request) }, status: :created
      rescue ActiveRecord::RecordNotUnique
        render json: { data: request_json(worker.leave_requests.find_by!(request_key: params.dig(:leave_request, :request_key))) }
      end

      private

      def request_json(request)
        request.as_json(only: %i[id leave_type starts_on ends_on hours reason status reviewed_at review_note])
      end
    end
  end
end
