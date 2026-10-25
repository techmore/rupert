# frozen_string_literal: true

# Owner-made training modules (Team → Training). hr.read sees modules, progress and history; hr.write adds and edits
# modules, files and assignments. Everything is read through the current workspace.
class TrainingModulesController < AuthenticatedController
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :set_module, only: %i[show edit update]

  def index
    authorize(:module, :hr_read?)
    @modules = TrainingModule.ordered.to_a
    counts = TrainingAssignment.group(:training_module_id, :status).count
    @overdue = TrainingAssignment.overdue.group(:training_module_id).count
    @counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    counts.each { |(module_id, status), count| @counts[module_id][status] = count }
    @totals = TrainingAssignment.group(:status).count
    @overdue_total = @overdue.values.sum
  end

  def show
    authorize(:module, :hr_read?)
    @attachments = @module.attachments.select(TrainingAttachment.column_names - ['content_base64']).to_a
    @assignments = @module.assignments.includes(:assignee).by_due.to_a
    @events = TrainingAssignmentEvent.where(training_assignment_id: @assignments.map(&:id)).includes(training_assignment: :assignee)
      .order(created_at: :desc, id: :desc).limit(100).to_a
    @can_write = Current.user.can?('hr.write')
    load_assign_choices if @can_write
  end

  def new
    authorize(:module, :hr_write?)
    @module = TrainingModule.new
  end

  def create
    authorize(:module, :hr_write?)
    @module = TrainingModule.new(module_params.merge(created_by: Current.user, updated_by: Current.user))
    if @module.save
      ActivityLogger.log('training_module_created', subject: @module, details: "Revision #{@module.revision}")
      redirect_to training_module_path(@module), notice: 'Training module added. Add files or assign it below.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize(:module, :hr_write?)
  end

  def update
    authorize(:module, :hr_write?)
    if @module.update(module_params.merge(updated_by: Current.user))
      ActivityLogger.log('training_module_updated', subject: @module, details: "Revision #{@module.revision}")
      redirect_to training_module_path(@module), notice: 'Training module saved.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_module
    @module = TrainingModule.find_by!(tenant_id: Current.tenant_id, id: params[:id])
  end

  def module_params
    params.require(:training_module).permit(:title, :body, :video_url)
  end

  def load_assign_choices
    @people = User.where(tenant_id: Current.tenant_id).active.ordered.to_a
    @departments = People::Department.ordered.to_a
    @roles = @people.map(&:role).uniq.sort
  end
end
