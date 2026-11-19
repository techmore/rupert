# frozen_string_literal: true

# My courses (the Learning center home), one course, and its badge.
class Lms::CoursesController < Lms::BaseController
  # Self-service: only the signed-in account's own enrollments are read or written.
  skip_after_action :verify_authorized

  def index
    Lms::Seeder.ensure!
    Lms::Enroller.ensure_for(Current.user)
    @courses = Lms::Course.published.ordered.includes(:lessons).to_a
    @enrollments = Lms::Enrollment.for_user(Current.user).includes(:lesson_progresses).index_by(&:course_id)
    @required = @courses.select { |course| @enrollments[course.id]&.required? }
    @other = @courses - @required
    @badges = @enrollments.values.select(&:completed?).sort_by(&:completed_at).reverse
  end

  def show
    load_course
    load_enrollment
    @next_lesson = @enrollment.next_lesson
  end

  def badge
    load_course
    @enrollment = Lms::Enrollment.find_by(course_id: @course.id, user_id: Current.user.id)
    redirect_to lms_course_path(@course), alert: t('lms.badge.not_yet') unless @enrollment&.completed?
  end
end
