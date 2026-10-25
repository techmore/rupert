# frozen_string_literal: true

# Assigning a training module (hr.write): to chosen people, everyone with a role, or everyone in a department with a
# linked account. People who already have the module open are skipped. Cancelling is the manager's only transition.
class TrainingAssignmentsController < AuthenticatedController
  def create
    authorize(:module, :hr_write?)
    training_module = TrainingModule.find_by!(tenant_id: Current.tenant_id, id: params[:training_module_id])
    back = training_module_path(training_module, anchor: 'assignments')
    due_on = parse_due_on
    return redirect_to(back, alert: 'Enter the due date as a real calendar date, today or later.') if due_on == :invalid

    people = chosen_people
    return redirect_to(back, alert: 'Choose at least one person, a role or a department.') if people.empty?

    created, skipped = TrainingAssignment.assign!(training_module, people, due_on: due_on, actor: Current.user)
    created.each do |assignment|
      ActivityLogger.log('training_assigned', subject: training_module,
        details: "#{assignment.assignee.display_name}#{" · due #{due_on.iso8601}" if due_on}")
    end
    notice = "Assigned to #{helpers.pluralize(created.size, 'person', plural: 'people')}."
    notice += " #{helpers.pluralize(skipped.size, 'person', plural: 'people')} already had it open." if skipped.any?
    redirect_to back, notice: notice
  end

  def cancel
    authorize(:module, :hr_write?)
    assignment = find_assignment
    return redirect_to(training_module_path(assignment.training_module, anchor: 'assignments'), alert: 'That page was out of date. Try again.') if @moved

    assignment.transition!('cancel', actor: Current.user, note: params[:note])
    redirect_to training_module_path(assignment.training_module, anchor: 'assignments'), notice: 'Assignment cancelled.'
  rescue TrainingAssignment::TransitionRefused => e
    redirect_to training_module_path(assignment.training_module, anchor: 'assignments'), alert: e.message
  end

  private

  # By id; an id the assignment had before the move to the shared table (#409) finds it too, without acting on it.
  def find_assignment
    assignment = TrainingAssignment.find_by(tenant_id: Current.tenant_id, id: params[:id])
    return assignment if assignment

    moved = TrainingAssignment::Legacy.where(id: params[:id].to_s).pick(:work_item_id)
    @moved = true
    TrainingAssignment.find_by!(tenant_id: Current.tenant_id, id: moved)
  end

  def parse_due_on
    return nil if params[:due_on].blank?

    date = Date.iso8601(params[:due_on].to_s)
    date < Date.current ? :invalid : date
  rescue Date::Error
    :invalid
  end

  def chosen_people
    people = User.where(tenant_id: Current.tenant_id).active
    ids = Array(params[:assignee_ids]).compact_blank.map(&:to_s)
    chosen = ids.any? ? people.where(id: ids).to_a : []
    chosen += people.where(role: params[:role].to_s).to_a if params[:role].present?
    if params[:department_id].present?
      user_ids = People::Employee.active.where(department_id: params[:department_id].to_s).where.not(user_id: nil).pluck(:user_id)
      chosen += people.where(id: user_ids).to_a
    end
    chosen.uniq(&:id)
  end
end
