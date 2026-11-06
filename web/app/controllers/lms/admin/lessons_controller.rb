# frozen_string_literal: true

# Editing one lesson's text, diagram and quiz (hr.write).
class Lms::Admin::LessonsController < Lms::BaseController
  before_action -> { authorize(:module, :hr_write?) }
  before_action :load_course
  before_action :load_lesson, except: :preview

  def edit; end

  def update
    @lesson.questions.each { |question| question.tenant_id ||= Current.tenant_id }
    if @lesson.update(lesson_params)
      @lesson.questions.each { |question| question.update_columns(tenant_id: Current.tenant_id) if question.tenant_id.blank? }
      @course.touch_edited!(Current.user)
      ActivityLogger.log('lms_lesson_updated', subject: @lesson, details: @course.title)
      redirect_to edit_lms_admin_course_path(@course), notice: t('lms.admin.saved')
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def preview
    @blocks = Lms::Markup.render(params[:body].to_s.first(Lms::Lesson::BODY_LIMIT), glossary: @course.glossary)
    render partial: 'lms/lessons/body', locals: { blocks: @blocks, course: @course }, layout: false
  end

  private

  def load_course
    @course = Lms::Course.includes(:lessons, :glossary_terms).find_by!(slug: params[:course_slug])
  end

  def load_lesson
    @lesson = @course.lessons.find { |lesson| lesson.slug == params[:slug] } or raise ActiveRecord::RecordNotFound
  end

  def lesson_params
    params.require(:lms_lesson).permit(:title, :summary, :minutes, :body, :diagram,
      questions_attributes: %i[id prompt choices_text answer_index explanation position _destroy])
  end
end
