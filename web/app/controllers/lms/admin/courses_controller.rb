# frozen_string_literal: true

# Editing courses (hr.write): title, summary, status, who gets it, and who to call.
class Lms::Admin::CoursesController < Lms::BaseController
  before_action -> { authorize(:module, :hr_write?) }
  before_action :load_any_course, only: %i[edit update]

  def index
    Lms::Seeder.ensure!
    @courses = Lms::Course.ordered.includes(:lessons, :assignment_rules).to_a
    @contacts = Lms::SupportContacts.for_tenant
  end

  def edit
    @rules = @course.assignment_rules.to_a
    @people = User.where(tenant_id: Current.tenant_id).active.ordered.to_a
    @enrollments = @course.enrollments.includes(:user).to_a.sort_by { |enrollment| enrollment.user.display_name.to_s }
  end

  def update
    if @course.update(course_params.merge(updated_by: Current.user))
      @course.touch_edited!(Current.user)
      ActivityLogger.log('lms_course_updated', subject: @course)
      redirect_to edit_lms_admin_course_path(@course), notice: t('lms.admin.saved')
    else
      edit
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def load_any_course
    @course = Lms::Course.includes(:lessons).find_by!(slug: params[:slug])
  end

  def course_params
    params.require(:lms_course).permit(:title, :summary, :description, :status, :badge_title)
  end
end
