# frozen_string_literal: true

module People
  # Timesheets: an employee records hours per day, submits for review, and a
  # manager approves or rejects. Entries are edited inline on the show page.
  class TimesheetsController < AuthenticatedController
    before_action :set_timesheet, only: [:show, :edit, :update, :destroy, :submit, :approve, :reject, :reopen, :add_entry, :remove_entry]

    def index
      authorize(:module, :timesheets_read?)
      @status = params[:status].presence || "all"
      @period = params[:period].presence || "all"
      @timesheets = People::Timesheet.by_status(@status)
      @timesheets = @timesheets.where(period_start: @period.to_date.beginning_of_week..@period.to_date.end_of_week) if @period != "all"
      @timesheets = @timesheets.recent(200).includes(:employee)
      @awaiting = People::Timesheet.awaiting_review.count
    end

    def show
      authorize(@timesheet)
      @entry = People::TimesheetEntry.new(timesheet: @timesheet, worked_on: Date.today)
    end

    def new
      authorize(:module, :timesheets_write?)
      monday = Date.today.beginning_of_week
      @timesheet = People::Timesheet.new(period_start: monday, period_end: monday + 6)
      @employees = People::Employee.active.ordered
    end

    def create
      authorize(:module, :timesheets_write?)
      @timesheet = People::Timesheet.new(timesheet_params)
      if @timesheet.save
        ActivityLogger.log("timesheet_created", subject: @timesheet, details: @timesheet.employee&.name)
        redirect_to(people_timesheet_path(@timesheet), notice: "Timesheet created — add daily hours.")
      else
        @employees = People::Employee.active.ordered
        render(:new, status: :unprocessable_entity)
      end
    end

    def edit
      authorize(:module, :timesheets_write?)
      return redirect_to(people_timesheet_path(@timesheet), alert: "Only draft timesheets can be edited.") unless @timesheet.draft?

      @employees = People::Employee.active.ordered
    end

    def update
      authorize(:module, :timesheets_write?)
      if @timesheet.update(timesheet_params)
        redirect_to(people_timesheet_path(@timesheet), notice: "Timesheet updated.")
      else
        @employees = People::Employee.active.ordered
        render(:edit, status: :unprocessable_entity)
      end
    end

    def destroy
      authorize(:module, :timesheets_write?)
      return redirect_to(people_timesheet_path(@timesheet), alert: "Only draft timesheets can be deleted.") unless @timesheet.draft?

      @timesheet.destroy
      redirect_to(people_timesheets_path, notice: "Timesheet deleted.")
    end

    def submit
      authorize(:module, :timesheets_write?)
      if @timesheet.entries.empty?
        return redirect_to(people_timesheet_path(@timesheet), alert: "Add at least one entry before submitting.")
      end

      @timesheet.submit!
      ActivityLogger.log("timesheet_submitted", subject: @timesheet)
      redirect_to(people_timesheet_path(@timesheet), notice: "Timesheet submitted for review.")
    end

    def approve
      authorize(:module, :timesheets_write?)
      @timesheet.approve! if @timesheet.may_approve?
      @timesheet.update!(reviewed_by: Current.user.id, reviewed_at: Time.current)
      ActivityLogger.log("timesheet_approved", subject: @timesheet)
      redirect_to(people_timesheet_path(@timesheet), notice: "Timesheet approved.")
    end

    def reject
      authorize(:module, :timesheets_write?)
      @timesheet.reject! if @timesheet.may_reject?
      @timesheet.update!(reviewed_by: Current.user.id, reviewed_at: Time.current)
      ActivityLogger.log("timesheet_rejected", subject: @timesheet)
      redirect_to(people_timesheet_path(@timesheet), notice: "Timesheet rejected.")
    end

    def reopen
      authorize(:module, :timesheets_write?)
      @timesheet.reopen! if @timesheet.may_reopen?
      ActivityLogger.log("timesheet_reopened", subject: @timesheet)
      redirect_to(people_timesheet_path(@timesheet), notice: "Timesheet reopened.")
    end

    def add_entry
      authorize(:module, :timesheets_write?)
      return redirect_to(people_timesheet_path(@timesheet), alert: "Only draft timesheets can be edited.") unless @timesheet.draft?

      @entry = @timesheet.entries.new(entry_params)
      if @entry.save
        redirect_to(people_timesheet_path(@timesheet), notice: "Entry added.")
      else
        render(:show, status: :unprocessable_entity)
      end
    end

    def remove_entry
      authorize(:module, :timesheets_write?)
      return redirect_to(people_timesheet_path(@timesheet), alert: "Only draft timesheets can be edited.") unless @timesheet.draft?

      @timesheet.entries.find_by(id: params[:entry_id])&.destroy
      redirect_to(people_timesheet_path(@timesheet), notice: "Entry removed.")
    end

    private

    def set_timesheet
      @timesheet = People::Timesheet.find_by!(tenant_id: Current.tenant_id, id: params[:id])
    end

    def timesheet_params
      params.require(:timesheet).permit(:employee_id, :period_start, :period_end, :notes)
    end

    def entry_params
      params.require(:timesheet_entry).permit(:worked_on, :hours, :work_type)
    end
  end
end
