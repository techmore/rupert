# frozen_string_literal: true

module Api
  module V1
    class EmployeeClockController < EmployeeBaseController
      rescue_from TimeClockService::Error, with: :invalid
      before_action -> { TimeClockService.require_channel!('api') }, only: %i[create update start_break end_break]
      before_action { Current.metadata[:punch_ip] = request.remote_ip }
      def index
        shifts = ClockShift.where(employee_id: worker.id, user_id: Current.user.id).recent.includes(:breaks).limit(100)
        render json: { data: shifts.map { |s| s.as_json(only: %i[id started_at ended_at source location_id]).merge('breaks' => s.breaks.as_json(only: %i[id kind paid started_at ended_at])) } }
      end

      def create
        shift = TimeClockService.clock_in(user: Current.user, request_token: params[:request_token].to_s, source: 'api')
        render json: { data: shift.as_json(only: %i[id started_at ended_at]) }, status: :created
      end

      def update
        shift = TimeClockService.clock_out(user: Current.user, shift_id: params[:id])
        render json: { data: shift.as_json(only: %i[id started_at ended_at]) }
      end

      # Breaks on the worker's own open shift: POST starts one ({kind: 'rest'|'meal'}), PATCH ends it.
      def start_break
        shift = ClockShift.open.find_by!(id: params[:id], employee_id: worker.id)
        pause = TimeClockService.start_break(shift: shift, kind: params[:kind].presence || 'rest')
        render json: { data: pause.as_json(only: %i[id kind paid started_at ended_at]) }, status: :created
      end

      def end_break
        shift = ClockShift.open.find_by!(id: params[:id], employee_id: worker.id)
        raise ActiveRecord::RecordNotFound unless shift.breaks.open.exists?(id: params[:break_id])

        pause = TimeClockService.end_break(shift: shift)
        render json: { data: pause.as_json(only: %i[id kind paid started_at ended_at]) }
      end

      def correction
        record = TimeClockService.request_correction(user: Current.user, shift_id: params[:id],
          attributes: params.require(:clock_correction).permit(:proposed_started_at, :proposed_ended_at, :reason).to_h.symbolize_keys)
        render json: { data: record.as_json(only: %i[id status reason proposed_started_at proposed_ended_at]) }, status: :created
      end
    end
  end
end
