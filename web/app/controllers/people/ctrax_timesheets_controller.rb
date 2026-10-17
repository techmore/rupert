# frozen_string_literal: true

require 'csv'

module People
  class CtraxTimesheetsController < AuthenticatedController
    before_action -> { response.headers['Cache-Control'] = 'no-store' }

    def index
      authorize(People::Timesheet, :index?)
      scope = CtraxLaborShift.visible_to(Current.user)
      @all_employees = Current.user.can_review_timesheets? || (Current.user.can_manage_accounts? && Current.user.can?('timesheets.read'))
      @employees = People::Employee.where(id: scope.select(:employee_id)).order(:last_name, :first_name) if @all_employees
      if @all_employees && params[:employee_id].present?
        scope = params[:employee_id] == 'unmatched' ? scope.where(employee_id: nil) : scope.where(employee_id: params[:employee_id])
      end
      scope = scope.where(status: params[:status]) if CtraxLaborShift::STATUSES.include?(params[:status])
      scope = scope.where('started_at >= ?', Date.iso8601(params[:from]).in_time_zone) if params[:from].present?
      scope = scope.where('started_at < ?', (Date.iso8601(params[:to]) + 1).in_time_zone) if params[:to].present?
      @count = scope.count
      @open = scope.where(in_progress: true).count
      @held = scope.where.not(status: 'imported').count
      if request.format.csv?
        data = CSV.generate do |csv|
          csv << ['Employee', 'C-Trax shift ID', 'Store ID', 'Clock-in', 'Clock-out', 'Source-reported hours', 'Elapsed hours', 'In progress', 'Source verified', 'Status', 'Review issue']
          scope.includes(:employee).find_each do |shift|
            csv << [shift.employee&.name, shift.external_id, shift.store_id, shift.started_at&.iso8601, shift.ended_at&.iso8601,
              shift.reported_hours, shift.elapsed_hours, shift.in_progress, shift.verified, shift.status, shift.issue].map { |value| TimesheetCsv.cell(value) }
          end
        end
        return send_data data, filename: 'ctrax-shift-history.csv', type: 'text/csv'
      end
      @pagy, @shifts = pagy(scope.order(started_at: :desc, id: :desc).includes(:employee), items: 30)
    rescue Date::Error
      redirect_to people_ctrax_timesheets_path, alert: 'Choose valid dates.'
    end

    def show
      @shift = CtraxLaborShift.visible_to(Current.user).includes(:employee).find(params[:id])
    end
  end
end
