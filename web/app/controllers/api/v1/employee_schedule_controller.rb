# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/employee/schedule?week=YYYY-MM-DD — the worker's posted shifts and the open shifts
    # they could pick up for one Monday–Sunday week. Drafts are never returned.
    class EmployeeScheduleController < EmployeeBaseController
      before_action -> { require_time_feature(:scheduling) }
      def index
        week = (params[:week].present? ? Date.iso8601(params[:week].to_s) : Date.current).beginning_of_week
        mine = worker.scheduled_shifts.live.published.between(week, week + 6).chronological.includes(:location, :position)
        open = People::ScheduledShift.open_shifts.published.between(week, week + 6).chronological.includes(:location, :position)
          .select { |s| worker.works_at?(s.location_id) && s.starts_at > Time.current }
        render json: { week_start: week.iso8601, data: mine.map { |s| shift_json(s) }, open_shifts: open.map { |s| shift_json(s) } }
      rescue Date::Error
        render json: { error: 'invalid_request', message: 'Choose a valid week.' }, status: :unprocessable_entity
      end

      private

      def shift_json(shift)
        { id: shift.id, starts_at: shift.starts_at.iso8601, ends_at: shift.ends_at.iso8601, hours: shift.paid_hours.round(2),
          break_minutes: shift.break_minutes, role: shift.label, store: shift.location&.name, notes: shift.notes, open: shift.open? }
      end
    end
  end
end
