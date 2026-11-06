# frozen_string_literal: true

require 'test_helper'

class Lms::ProgressTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    @course = Lms::Course.create!(slug: 'progress', title: 'Progress', status: 'published')
    @l1 = @course.lessons.create!(slug: 'l1', title: 'L1', body: 'x', position: 1)
    @l2 = @course.lessons.create!(slug: 'l2', title: 'L2', body: 'y', position: 2)
    @q = @l1.questions.create!(prompt: 'Q', choices: %w[a b], answer_index: 1)
    @enrollment = Lms::Enroller.self_enroll!(@course, @user)
    @progress = Lms::Progress.new(@enrollment)
  end

  teardown { Current.reset }

  test 'viewing a lesson starts the course and remembers where the person is' do
    assert_equal 'assigned', @enrollment.status
    @progress.viewed!(@l2)
    @enrollment.reload
    assert_equal 'in_progress', @enrollment.status
    assert @enrollment.started_at.present?
    assert_equal @l2, @enrollment.current_lesson
    assert @enrollment.progress_for(@l2).viewed?
    refute @enrollment.passed?(@l2)
    assert_equal [0, 2], @enrollment.progress
  end

  test 'a failed quiz records the attempt without passing' do
    result = @progress.answer!(@l1, { @q.id.to_s => '0' })
    refute result.passed?
    progress = @enrollment.reload.progress_for(@l1)
    assert_equal 1, progress.attempts
    assert_equal 0, progress.best_score
    refute progress.passed?
    assert_equal 1, progress.quiz_attempts.count
    refute progress.quiz_attempts.first.passed?
    assert_equal 'in_progress', @enrollment.status
  end

  test 'passing every lesson completes the course once and awards the badge' do
    @progress.answer!(@l1, { @q.id.to_s => '0' })
    @progress.answer!(@l1, { @q.id.to_s => '1' })
    @enrollment.reload
    assert @enrollment.passed?(@l1)
    assert_equal 2, @enrollment.progress_for(@l1).attempts
    assert_equal 100, @enrollment.progress_for(@l1).best_score
    refute @enrollment.completed?
    assert_equal @l2, @enrollment.next_lesson

    @progress.answer!(@l2, {})
    @enrollment.reload
    assert @enrollment.completed?
    assert @enrollment.completed_at.present?
    assert @enrollment.badge_awarded_at.present?
    assert_equal 100, @enrollment.percent
    assert_nil @enrollment.next_lesson
    assert ActivityLog.where(action: 'lms_course_completed').exists?

    first_completed = @enrollment.completed_at
    travel 1.hour do
      @progress.answer!(@l1, { @q.id.to_s => '1' })
      assert_equal first_completed, @enrollment.reload.completed_at
    end
  end

  test 'quiz attempts are append-only' do
    @progress.answer!(@l1, { @q.id.to_s => '1' })
    attempt = Lms::QuizAttempt.last
    assert_raises(ActiveRecord::RecordNotDestroyed) { attempt.destroy! }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { attempt.update!(correct_count: 0) }
  end
end
