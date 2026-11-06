# frozen_string_literal: true

module People
  # Reusable weeks for the schedule builder: save the shown week as a template, apply one to a week.
  class ScheduleTemplatesController < AuthenticatedController
    before_action { authorize(:module, :schedule_write?) }
    before_action :set_template, only: %i[apply destroy]
    rescue_from Date::Error, with: :invalid_week

    def index
      @templates = People::ScheduleTemplate.ordered.includes(:shifts, :location).to_a
    end

    def new
      @week = week_param
      @location_id = params[:location_id].presence
      @template = People::ScheduleTemplate.new(name: "Week of #{@week.strftime('%b %-d')}", location_id: @location_id)
      @shift_count = People::ScheduledShift.between(@week, @week + 6).live.for_location(@location_id).count
    end

    def create
      @week = week_param
      @location_id = params[:location_id].presence
      @template = People::ScheduleTemplate.new(name: params.dig(:schedule_template, :name).to_s.strip, location_id: @location_id, created_by: Current.user)
      if @template.save
        @template.capture_week!(@week, location_id: @location_id)
        ActivityLogger.log('schedule_template_saved', subject: @template, details: "#{@template.shifts.count} shifts from the week of #{@week.strftime('%b %-d, %Y')}")
        redirect_to(people_scheduled_shifts_path(week: @week.iso8601, location_id: @location_id), notice: "Saved “#{@template.name}” with #{helpers.pluralize(@template.shifts.count, 'shift')}.")
      else
        @shift_count = People::ScheduledShift.between(@week, @week + 6).live.for_location(@location_id).count
        render :new, status: :unprocessable_entity
      end
    end

    def apply
      week = week_param
      created, skipped = @template.apply_to_week!(week, location_id: params[:location_id].presence)
      ActivityLogger.log('schedule_template_applied', subject: @template, details: "Week of #{week.strftime('%b %-d, %Y')}: #{created.size} added, #{skipped} skipped")
      message = "Added #{helpers.pluralize(created.size, 'draft shift')} from “#{@template.name}”."
      message += " Skipped #{skipped}: they overlap a shift already planned or the person is no longer active." if skipped.positive?
      redirect_to(people_scheduled_shifts_path(week: week.iso8601, location_id: params[:location_id].presence), notice: message)
    end

    def destroy
      @template.destroy!
      redirect_to(people_schedule_templates_path, notice: 'Template removed.')
    end

    private

    def set_template
      @template = People::ScheduleTemplate.find(params[:id])
    end

    def week_param
      day = params[:week].present? ? Date.iso8601(params[:week].to_s) : Date.current
      raise Date::Error unless (1900..2100).cover?(day.year)

      day.beginning_of_week
    end

    def invalid_week
      redirect_to(people_scheduled_shifts_path, alert: 'Choose a valid week.')
    end
  end
end
