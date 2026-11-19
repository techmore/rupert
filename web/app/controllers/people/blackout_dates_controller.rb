# frozen_string_literal: true

module People
  # Dates when time off is not granted (Settings template). Staff see them before they ask.
  class BlackoutDatesController < AuthenticatedController
    before_action { authorize(:module, :leave_write?) }

    def index
      @blackouts = People::BlackoutDate.order(:starts_on).includes(:location).to_a
      @locations = Location.for_shifts.to_a
      @blackout = People::BlackoutDate.new(starts_on: Date.current, ends_on: Date.current)
    end

    def create
      @blackout = People::BlackoutDate.new(params.require(:blackout_date).permit(:starts_on, :ends_on, :reason, :location_id).merge(created_by: Current.user))
      if @blackout.save
        ActivityLogger.log('blackout_date_added', subject: @blackout, details: "#{@blackout.label}: #{@blackout.reason}")
        redirect_to people_blackout_dates_path, notice: 'Blackout dates saved.'
      else
        @blackouts = People::BlackoutDate.order(:starts_on).includes(:location).to_a
        @locations = Location.for_shifts.to_a
        render :index, status: :unprocessable_entity
      end
    end

    def destroy
      blackout = People::BlackoutDate.find(params[:id])
      blackout.destroy!
      ActivityLogger.log('blackout_date_removed', subject: blackout, details: blackout.label)
      redirect_to people_blackout_dates_path, notice: 'Blackout dates removed.'
    end
  end
end
