# frozen_string_literal: true

require 'test_helper'

class Lms::QuizGraderTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @course = Lms::Course.create!(slug: 'grader', title: 'Grader', status: 'published')
    @lesson = @course.lessons.create!(slug: 'one', title: 'One', body: 'x')
    @q1 = @lesson.questions.create!(prompt: 'Q1', choices: %w[a b c], answer_index: 1, explanation: 'b it is')
    @q2 = @lesson.questions.create!(prompt: 'Q2', choices: %w[yes no], answer_index: 0)
  end

  teardown { Current.reset }

  test 'all right passes with a full score' do
    result = Lms::QuizGrader.grade(@lesson, { @q1.id.to_s => '1', @q2.id.to_s => '0' })
    assert result.passed?
    assert_equal 100, result.score
    assert_empty result.wrong
  end

  test 'one wrong fails, names the question and keeps the score' do
    result = Lms::QuizGrader.grade(@lesson, { @q1.id.to_s => '2', @q2.id.to_s => '0' })
    refute result.passed?
    assert_equal [@q1], result.wrong
    assert_equal 50, result.score
    assert result.wrong?(@q1)
    assert_equal '2', result.answered(@q1)
  end

  test 'missing, out-of-range and foreign answers are dropped and count as wrong' do
    result = Lms::QuizGrader.grade(@lesson, { @q1.id.to_s => '9', '999999' => '0', 'junk' => 'x' })
    assert_equal({}, result.answers)
    assert_equal 2, result.wrong.size
    assert_equal 0, result.score
  end

  test 'action controller parameters are accepted' do
    params = ActionController::Parameters.new(@q1.id.to_s => '1', @q2.id.to_s => '0')
    assert Lms::QuizGrader.grade(@lesson, params).passed?
  end

  test 'a lesson without questions passes on sight' do
    empty = @course.lessons.create!(slug: 'two', title: 'Two', body: 'x')
    result = Lms::QuizGrader.grade(empty, nil)
    assert result.passed?
    assert_equal 100, result.score
  end
end
