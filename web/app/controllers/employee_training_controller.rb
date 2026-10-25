# frozen_string_literal: true

# The signed-in person's own training (/employee/training). Every lookup starts from the assignments assigned to
# Current.user in the current workspace, so another person's assignment, or a module nobody assigned, is a 404.
# A cancelled assignment is no longer readable here. Assignments live in the shared work-item table (#409); a link
# with the id an assignment had before the move (training_assignments.id) is sent to its new id.
class EmployeeTrainingController < AuthenticatedController
  layout 'employee'
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  before_action :set_assignment, except: :index

  def index
    assignments = mine.includes(:training_module).by_due.to_a
    @open = assignments.select(&:open?)
    @completed = assignments.select(&:completed?).sort_by(&:completed_at).reverse
  end

  def show
    @attachments = @assignment.training_module.attachments.select(TrainingAttachment.column_names - ['content_base64']).to_a
    @events = @assignment.events.to_a
  end

  def start
    change('start', 'Training started. Mark it complete when you have finished.')
  end

  def complete
    change('complete', 'Training complete. Your manager can see it.')
  end

  def file
    attachment = @assignment.training_module.attachments.find(params[:file_id])
    send_data(attachment.bytes, filename: attachment.filename, type: attachment.content_type, disposition: 'attachment')
  end

  private

  def mine
    TrainingAssignment.for_user(Current.user).where.not(status: 'cancelled')
  end

  def set_assignment
    @assignment = mine.find_by(id: params[:id])
    return if @assignment

    moved = TrainingAssignment::Legacy.work_item_id_for(params[:id], Current.user)
    raise ActiveRecord::RecordNotFound unless moved && mine.exists?(id: moved)

    # An old link: show the same assignment at its new address (a form posted from an old page is not replayed).
    target = action_name == 'file' ? employee_training_file_path(moved, params[:file_id]) : employee_training_path(moved)
    redirect_to target, status: request.get? ? :moved_permanently : :see_other
  end

  def change(event, notice)
    @assignment.transition!(event, actor: Current.user)
    redirect_to employee_training_path(@assignment), notice: notice
  rescue TrainingAssignment::TransitionRefused => e
    redirect_to employee_training_path(@assignment), alert: e.message
  end
end
