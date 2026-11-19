# frozen_string_literal: true

# A worker's own availability blocks (when they cannot or prefer to work).
class EmployeeAvailabilityController < AuthenticatedController
  layout 'employee'
  before_action { response.headers['Cache-Control'] = 'no-store' }
  before_action :require_worker
  before_action -> { require_time_feature(:scheduling) }

  def index
    @blocks = @worker.availabilities.ordered.to_a
  end

  def create
    block = @worker.availabilities.new(People::AvailabilityParams.normalize(params.require(:employee_availability).permit(:weekday, :kind, :start_time, :end_time, :note, :all_day)))
    if block.save
      redirect_to employee_availability_index_path, notice: t('time.schedule.availability.saved')
    else
      redirect_to employee_availability_index_path, alert: block.errors.full_messages.to_sentence
    end
  end

  def destroy
    @worker.availabilities.find(params[:id]).destroy!
    redirect_to employee_availability_index_path, notice: t('time.schedule.availability.removed')
  end

  private

  def require_worker
    @worker = TimeClockService.worker_for(Current.user, include_on_leave: true)
    return skip_authorization if @worker

    redirect_to employee_app_path, alert: 'Ask an administrator to link your staff record first.'
  end
end
