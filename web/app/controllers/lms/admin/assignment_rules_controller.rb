# frozen_string_literal: true

# "Everyone with this role takes this course" rules (hr.write). Adding a rule enrols the people
# it reaches now; removing it leaves their enrollments (what someone learned is not undone).
class Lms::Admin::AssignmentRulesController < Lms::BaseController
  before_action -> { authorize(:module, :hr_write?) }
  before_action :load_course

  def create
    rule = @course.assignment_rules.build(rule_params.merge(created_by: Current.user, tenant_id: Current.tenant_id))
    if rule.save
      created = Lms::Enroller.apply_rule!(rule)
      ActivityLogger.log('lms_rule_added', subject: @course, details: "#{rule.role_label}, #{created.size} enrolled")
      redirect_to edit_lms_admin_course_path(@course), notice: t('lms.admin.rule_added', count: created.size)
    else
      redirect_to edit_lms_admin_course_path(@course), alert: rule.errors.full_messages.to_sentence
    end
  end

  def destroy
    rule = @course.assignment_rules.find(params[:id])
    rule.destroy!
    ActivityLogger.log('lms_rule_removed', subject: @course, details: rule.role_label)
    redirect_to edit_lms_admin_course_path(@course), notice: t('lms.admin.rule_removed')
  end

  private

  def load_course
    @course = Lms::Course.find_by!(slug: params[:course_slug])
  end

  # Read by hand: `role` here is the audience of a rule, not an account's role, and the model
  # validates it against the role list.
  def rule_params
    given = params.fetch(:lms_assignment_rule, {})
    { role: given[:role].to_s.presence, required: given[:required].to_s == '1', due_days: given[:due_days].to_s.presence }
  end
end
