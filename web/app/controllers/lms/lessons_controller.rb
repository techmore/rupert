# frozen_string_literal: true

# Reading a lesson records it as viewed; answering its quiz records the attempt and, when every
# answer is right, passes the lesson and possibly completes the course.
class Lms::LessonsController < Lms::BaseController
  skip_after_action :verify_authorized
  before_action :load_course, :load_enrollment, :load_lesson

  def show
    @progress = Lms::Progress.new(@enrollment).viewed!(@lesson)
    @result = nil
  end

  def quiz
    @result = Lms::Progress.new(@enrollment).answer!(@lesson, params[:answers])
    @progress = @enrollment.progress_for(@lesson)
    @enrollment.reload
    if @result.passed?
      just_completed = @enrollment.completed? && @enrollment.completed_at && @enrollment.completed_at > 5.seconds.ago
      return redirect_to badge_lms_course_path(@course), notice: t('lms.quiz.course_complete', course: @course.title) if just_completed

      next_lesson = @course.lesson_after(@lesson)
      destination = next_lesson ? lms_course_lesson_path(@course, next_lesson) : lms_course_path(@course)
      redirect_to destination, notice: t('lms.quiz.passed', lesson: @lesson.title)
    else
      flash.now[:alert] = t('lms.quiz.try_again', count: @result.wrong.size)
      render :show, status: :unprocessable_entity
    end
  end

  private

  def load_lesson
    @lesson = @course.lessons.find { |lesson| lesson.slug == params[:slug] } or raise ActiveRecord::RecordNotFound
    @blocks = Lms::Markup.render(@lesson.body, glossary: @course.glossary)
    @previous = @course.lesson_before(@lesson)
    @next = @course.lesson_after(@lesson)
  end
end
