# frozen_string_literal: true

# Assigning a course to named people (hr.write).
class Lms::Admin::EnrollmentsController < Lms::BaseController
  before_action -> { authorize(:module, :hr_write?) }

  def create
    course = Lms::Course.find_by!(slug: params[:course_slug])
    users = User.where(tenant_id: Current.tenant_id, id: Array(params[:user_ids]).map(&:to_i)).active.to_a
    return redirect_to edit_lms_admin_course_path(course), alert: t('lms.admin.pick_people') if users.empty?

    due_on = params[:due_on].present? ? Date.parse(params[:due_on]) : nil
    created, existing = Lms::Enroller.assign!(course, users, actor: Current.user, required: params[:required] == '1', due_on: due_on)
    ActivityLogger.log('lms_course_assigned', subject: course, details: "#{created.size} assigned, #{existing.size} already on it")
    redirect_to edit_lms_admin_course_path(course), notice: t('lms.admin.assigned', count: created.size, existing: existing.size)
  rescue Date::Error
    redirect_to edit_lms_admin_course_path(course), alert: t('lms.admin.bad_date')
  end
end
