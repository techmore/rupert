# frozen_string_literal: true

require 'test_helper'

# The Learning center end to end: a learner reads a lesson, fails and passes its quiz, finishes the
# course and gets the badge; team completion needs hr.read; editing needs hr.write; workspaces are
# isolated; drafts are hidden; the rail shows one entry.
class LmsFlowTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @manager = User.create!(tenant: @tenant, email: 'lms-manager@example.com', name: 'Mona Manager', role: 'manager', password: 'password123')
    @cashier = User.create!(tenant: @tenant, email: 'lms-cashier@example.com', name: 'Cal Cashier', role: 'cashier', password: 'password123')
    @staff = User.create!(tenant: @tenant, email: 'lms-staff@example.com', name: 'Sam Staff', role: 'employee', password: 'password123')
    Current.tenant = @tenant
    @course = Lms::Seeder.sync!.first
    @lessons = @course.lessons.to_a
    @first = @lessons.first
    Current.reset
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  # Test code runs outside a request, so workspace-scoped reads need the tenant set by hand.
  def with_tenant
    Current.tenant = @tenant
    yield
  ensure
    Current.reset
  end

  def questions_of(lesson) = with_tenant { lesson.questions.reload.to_a }
  def right_answers(lesson) = questions_of(lesson).to_h { |question| [question.id.to_s, question.answer_index.to_s] }
  def enrollment_of(user) = with_tenant { Lms::Enrollment.includes(:lesson_progresses).find_by!(course_id: @course.id, user_id: user.id) }
  def lesson_passed?(user, lesson) = with_tenant { enrollment_of(user).passed?(lesson) }

  test 'a manager is enrolled by the role rule and sees the course as required' do
    sign_in @manager
    get lms_root_path
    assert_response :success
    assert_select 'h1.page-title', text: 'Learning center'
    assert_select '#lms-required-title', text: 'Required for you'
    assert_select 'a[href=?]', lms_course_path(@course), text: @course.title
    assert_select 'a[href=?]', lms_team_path, text: 'Team completion'
    assert_select 'a[href=?]', lms_admin_courses_path, count: 0
    enrollment = enrollment_of(@manager)
    assert enrollment.required?
    assert_equal Date.current + 30, enrollment.due_on
    assert_select 'nav[aria-label="Module areas"], nav[aria-label="Module"]' do
      assert_select 'a[href=?]', lms_root_path
    end
  end

  test 'reading, failing, passing and finishing a course awards the badge' do
    sign_in @cashier
    get lms_course_path(@course)
    assert_response :success
    assert_select 'h1.page-title', text: @course.title
    assert_select 'a.btn-primary[href=?]', lms_course_lesson_path(@course, @first), text: 'Start the course'

    get lms_course_lesson_path(@course, @first)
    assert_response :success
    assert_select 'h1.page-title', text: @first.title
    assert_select 'figure.lms-figure', minimum: 1
    assert_select 'span.term.lesson-term button.term-label', minimum: 1
    assert_select 'fieldset.lms-question', count: questions_of(@first).size
    enrollment = enrollment_of(@cashier)
    assert_equal 'in_progress', enrollment.status
    assert_equal 'self', enrollment.source

    wrong = right_answers(@first)
    question = questions_of(@first).first
    wrong[question.id.to_s] = ((question.answer_index + 1) % question.choices.size).to_s
    post quiz_lms_course_lesson_path(@course, @first), params: { answers: wrong }
    assert_response :unprocessable_entity
    assert_select '#quiz-feedback', text: /One answer to revisit/
    assert_select 'fieldset.lms-question-wrong', count: 1
    assert_select 'fieldset.lms-question-right', count: questions_of(@first).size - 1
    assert_select '.lms-explanation', minimum: 1
    refute lesson_passed?(@cashier, @first)

    post quiz_lms_course_lesson_path(@course, @first), params: { answers: right_answers(@first) }
    assert_redirected_to lms_course_lesson_path(@course, @lessons.second)
    assert lesson_passed?(@cashier, @first)
    assert_equal 2, with_tenant { enrollment_of(@cashier).progress_for(@first).attempts }

    get lms_course_path(@course)
    assert_select 'a.btn-primary', text: 'Continue with lesson 2'
    assert_select 'li.lms-lesson-item-done', count: 1

    @lessons.drop(1).each do |lesson|
      post quiz_lms_course_lesson_path(@course, lesson), params: { answers: right_answers(lesson) }
      assert_response :redirect
    end
    assert_redirected_to badge_lms_course_path(@course)
    assert enrollment_of(@cashier).completed?
    follow_redirect!
    assert_response :success
    assert_select '.lms-badge-title', text: @course.badge_title
    assert_select 'dd', text: 'Cal Cashier'

    get lms_root_path
    assert_select '#lms-badges-title', text: 'Your badges'
    assert_select 'a.btn-ghost[href=?]', lms_course_path(@course), text: 'Review'
  end

  test 'the badge page refuses an unfinished course' do
    sign_in @cashier
    get badge_lms_course_path(@course)
    assert_redirected_to lms_course_path(@course)
  end

  test 'a lesson without a quiz passes when marked as read' do
    with_tenant { @first.questions.destroy_all }
    sign_in @cashier
    get lms_course_lesson_path(@course, @first)
    assert_select 'input[type=submit][value="Mark as read"]'
    post quiz_lms_course_lesson_path(@course, @first)
    assert_response :redirect
    assert lesson_passed?(@cashier, @first)
  end

  test 'staff accounts can learn and the lesson renders inside their shell' do
    sign_in @staff
    get lms_root_path
    assert_response :success
    assert_select 'a[href=?]', lms_root_path
    get lms_course_lesson_path(@course, @first)
    assert_response :success
    get lms_team_path
    assert_response :redirect
    get lms_admin_courses_path
    assert_response :redirect
  end

  test 'team completion needs hr.read and lists every person against the course' do
    sign_in @cashier
    get lms_team_path
    assert_redirected_to root_path
    assert_equal "You don't have permission to do that.", flash[:alert]

    sign_in @manager
    get lms_team_path
    assert_response :success
    assert_select 'h1.page-title', text: 'Team completion'
    assert_select 'td', text: /Cal Cashier/
    assert_select 'td', text: /Mona Manager/
    assert_select 'span.pill-taupe', text: 'Not assigned', minimum: 1
    get lms_team_path(status: 'assigned')
    assert_select 'td', text: /Mona Manager/, minimum: 1
    assert_select 'td', text: /Cal Cashier/, count: 0
    get lms_team_path(status: 'not_assigned')
    assert_select 'td', text: /Cal Cashier/, minimum: 1
    get lms_team_path(format: :csv)
    assert_response :success
    assert_includes response.body, 'Mona Manager'
    assert_equal 'text/csv', response.media_type
  end

  test 'managers without hr.write cannot edit; admins can edit a lesson, add a rule and assign people' do
    sign_in @manager
    get edit_lms_admin_course_path(@course)
    assert_redirected_to root_path
    patch lms_admin_course_path(@course), params: { lms_course: { title: 'Hacked' } }
    assert_redirected_to root_path
    assert_equal 'How our card payments work', @course.reload.title

    sign_in @admin
    get lms_admin_courses_path
    assert_response :success
    assert_select 'h1.page-title', text: 'Manage courses'
    get edit_lms_admin_course_path(@course)
    assert_response :success
    get edit_lms_admin_course_lesson_path(@course, @first)
    assert_response :success
    assert_select 'textarea#lms_lesson_body'

    question = questions_of(@first).first
    patch lms_admin_course_lesson_path(@course, @first), params: { lms_lesson: {
      title: 'Edited title', body: "New body with [[batch]].\n\n> tip: ok",
      questions_attributes: { '0' => { id: question.id, prompt: 'Edited?', choices_text: "No\nYes", answer_index: '1', explanation: 'Yes.' } }
    } }
    assert_redirected_to edit_lms_admin_course_path(@course)
    assert_equal 'Edited title', @first.reload.title
    assert_equal %w[No Yes], question.reload.choices
    assert_equal 1, question.answer_index
    assert @course.reload.edited_at.present?
    assert_nil Lms::Seeder.new(@tenant.id, YAML.safe_load_file(Lms::Seeder.files.first).merge('version' => 99)).sync!

    post preview_lms_admin_course_lessons_path(@course), params: { body: '**bold** <script>x</script>' }
    assert_response :success
    assert_includes response.body, '<strong>bold</strong>'
    refute_includes response.body, '<script>'

    post lms_admin_course_assignment_rules_path(@course), params: { lms_assignment_rule: { role: 'cashier', required: '1', due_days: '14' } }
    assert_redirected_to edit_lms_admin_course_path(@course)
    enrollment = enrollment_of(@cashier)
    assert enrollment.required?
    assert_equal Date.current + 14, enrollment.due_on

    post lms_admin_course_enrollments_path(@course), params: { user_ids: [@staff.id], due_on: (Date.current + 3).iso8601, required: '1' }
    assert_redirected_to edit_lms_admin_course_path(@course)
    staff_enrollment = enrollment_of(@staff)
    assert_equal 'manual', staff_enrollment.source
    assert_equal @admin, staff_enrollment.assigned_by

    patch lms_admin_support_contacts_path, params: { contacts: { valmar: { phone: '555-0100', notes: 'Ask for Pat' } } }
    assert_redirected_to lms_admin_courses_path
    assert_equal '555-0100', Lms::SupportContacts.for_tenant(@tenant.id).find { |contact| contact.key == 'valmar' }.phone
    get lms_course_lesson_path(@course, @lessons.last)
    assert_select '.lms-contacts a[href="tel:5550100"]', text: '555-0100'
  end

  test 'draft courses are hidden from learners and other workspaces see nothing' do
    Current.tenant = @tenant
    @course.update!(status: 'draft')
    Current.reset
    sign_in @cashier
    get lms_root_path
    assert_select '.empty-state-title', text: 'No courses yet.'
    get lms_course_path(@course)
    assert_response :not_found

    other = Tenant.create!(name: 'Other LMS', subdomain: "lms#{SecureRandom.hex(3)}")
    outsider = User.create!(tenant: other, email: 'out@example.com', role: 'admin', password: 'password123')
    delete logout_path
    sign_in outsider
    get lms_team_path
    assert_response :success
    assert_select 'td', text: /Cal Cashier/, count: 0
  end
end
