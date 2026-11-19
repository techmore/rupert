# frozen_string_literal: true

# Learning center pages. Learner pages read and write only the signed-in account's own
# enrollments and progress; team and admin pages authorize against hr.read / hr.write.
class Lms::BaseController < AuthenticatedController
  before_action -> { response.headers['Cache-Control'] = 'no-store' }
  # Staff accounts keep their own shell; everyone else gets the management shell.
  layout -> { Current.user&.employee? ? 'employee' : 'application' }

  private

  def load_course
    @course = Lms::Course.published.includes(:lessons, :glossary_terms).find_by!(slug: params[:course_slug] || params[:slug])
  end

  # The signed-in person's enrollment on the course, created on first visit (self-enrolment).
  def load_enrollment
    @enrollment = Lms::Enrollment.includes(:lesson_progresses).find_by(course_id: @course.id, user_id: Current.user.id) ||
                  Lms::Enroller.self_enroll!(@course, Current.user)
  end
end
