# frozen_string_literal: true

# Team completion (hr.read): who finished what, who is overdue, with a CSV for the records.
class Lms::TeamController < Lms::BaseController
  def index
    authorize(:module, :hr_read?)
    @report = Lms::TeamReport.new(course: params[:course].presence, role: params[:role].presence, status: params[:status].presence)
    respond_to do |format|
      format.html
      format.csv do
        log_export('Learning center team completion')
        send_data @report.to_csv, filename: "learning-center-#{Date.current}.csv", type: 'text/csv'
      end
    end
  end
end
