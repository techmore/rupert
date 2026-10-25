# frozen_string_literal: true

require 'test_helper'

# The training flow end to end (#399 #410 #411): a manager adds a module with a file and a video link and assigns it;
# the trainee starts and completes it from their own workspace; the manager sees progress and history. Staff reach only
# their own assignments, read-only managers cannot change anything, and another workspace cannot reach any of it.
class TrainingAssignmentsFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: 'lms-manager@example.com', name: 'Mona Manager', role: 'admin', password: 'password123')
    @viewer = User.create!(tenant: @tenant, email: 'lms-viewer@example.com', role: 'manager', password: 'password123')
    @staff = User.create!(tenant: @tenant, email: 'lms-staff@example.com', name: 'Sam Staff', role: 'employee', password: 'password123')
    @coworker = User.create!(tenant: @tenant, email: 'lms-coworker@example.com', name: 'Cora Coworker', role: 'employee', password: 'password123')
    Current.reset
  end

  teardown { Current.reset }

  test 'a manager configures and assigns a module, the trainee completes it, and the setup step ticks' do
    sign_in @manager
    get welcome_path
    assert_includes response.body, 'Configure, assign and complete a training module'
    get training_modules_path
    assert_response :success
    assert_select 'h1', 'Training'
    assert_includes response.body, 'No training modules yet.'

    post training_modules_path, params: { training_module: { title: 'Register opening', body: "Count the float.\n\nSign the sheet.", video_url: 'https://videos.example.com/opening' } }
    training_module = TrainingModule.unscoped.find_by!(title: 'Register opening')
    assert_redirected_to training_module_path(training_module)

    post training_module_attachments_path(training_module), params: { file: file('%PDF-1.4 float guide', 'float-guide.pdf') }
    assert_equal 1, TrainingAttachment.unscoped.where(training_module_id: training_module.id).count
    assert_equal 2, training_module.reload.revision
    post training_module_attachments_path(training_module), params: { file: file('<script>', 'page.html') }
    assert_match(/Only PDF/, flash[:alert])

    post training_module_assignments_path(training_module), params: { assignee_ids: [@staff.id], due_on: (Date.current + 3).iso8601 }
    assert_equal 'Assigned to 1 person.', flash[:notice]
    post training_module_assignments_path(training_module), params: { role: 'employee' }
    assert_equal 'Assigned to 1 person. 1 person already had it open.', flash[:notice]
    assignment = TrainingAssignment.unscoped.find_by!(assignee_id: @staff.id)
    assert_equal Date.current + 3, assignment.due_on
    assert ActivityLog.unscoped.where(tenant_id: @tenant.id, action: 'training_assigned').exists?

    sign_in @staff
    get employee_training_index_path
    assert_response :success
    assert_select "[data-assignment-id='#{assignment.id}']"
    get employee_training_path(assignment)
    assert_response :success
    assert_select 'a[href="https://videos.example.com/opening"][target="_blank"][rel~="noopener"]', text: 'Open video'
    assert_select 'iframe', count: 0
    file_row = TrainingAttachment.unscoped.find_by!(training_module_id: training_module.id)
    get employee_training_file_path(assignment, file_row)
    assert_equal '%PDF-1.4 float guide', response.body

    post complete_employee_training_path(assignment)
    assert_match(/Cannot complete/, flash[:alert])
    assert_equal 'assigned', assignment.reload.status
    post start_employee_training_path(assignment)
    assert_equal 'in_progress', assignment.reload.status
    post complete_employee_training_path(assignment)
    assignment.reload
    assert_equal ['completed', @staff.id, 2], [assignment.status, assignment.completed_by_id, assignment.completed_revision]
    get employee_training_index_path
    assert_includes response.body, 'Completed'

    sign_in @manager
    get training_module_path(training_module)
    assert_response :success
    assert_select "tr[data-assignment-id='#{assignment.id}'] .pill-fern", 'Completed'
    assert_select '#history li', count: 4 # two assigned, started, completed
    assert_includes response.body, 'revision 2'
    get learning_index_path
    checklist = GettingStartedChecklist.new(@manager.reload)
    assert checklist.items.find { |item| item.key == 'training_module' }.done?
    assert GettingStartedChecklist.new(@staff.reload).items.find { |item| item.key == 'my_training' }.done?
  end

  test 'staff reach only their own assignments' do
    training_module, mine, theirs = assigned_pair
    file_row = attach(training_module)
    sign_in @staff
    get employee_training_index_path
    assert_select "[data-assignment-id='#{mine.id}']"
    assert_select "[data-assignment-id='#{theirs.id}']", count: 0
    get employee_training_path(theirs)
    assert_response :not_found
    post start_employee_training_path(theirs)
    assert_response :not_found
    get employee_training_file_path(theirs, file_row)
    assert_response :not_found
    assert_equal 'assigned', theirs.reload.status

    get training_modules_path
    assert_response :redirect
    get training_module_path(training_module)
    assert_response :redirect
    get training_module_attachment_path(training_module, file_row)
    assert_not_equal '%PDF-1.4 x', response.body
    assert_no_difference -> { TrainingAssignment.unscoped.count } do
      post training_module_assignments_path(training_module), params: { assignee_ids: [@staff.id, @coworker.id] }
    end
    post cancel_training_assignment_path(mine)
    assert_equal 'assigned', mine.reload.status

    mine_cancelled = mine
    sign_in @manager
    post cancel_training_assignment_path(mine_cancelled)
    sign_in @staff
    get employee_training_path(mine_cancelled)
    assert_response :not_found
  end

  test 'hr.read sees progress but cannot change modules or assignments' do
    training_module, mine, = assigned_pair
    sign_in @viewer
    get training_modules_path
    assert_response :success
    assert_select 'a', text: 'Add training module', count: 0
    get training_module_path(training_module)
    assert_response :success
    assert_select 'form[action=?]', training_module_assignments_path(training_module), count: 0
    get new_training_module_path
    assert_response :redirect
    assert_no_difference -> { TrainingAssignment.unscoped.count } do
      post training_module_assignments_path(training_module), params: { assignee_ids: [@viewer.id] }
    end
    post cancel_training_assignment_path(mine)
    assert_equal 'assigned', mine.reload.status
    patch training_module_path(training_module), params: { training_module: { title: 'Hijacked' } }
    assert_equal 'Safety walk', training_module.reload.title
  end

  test 'another workspace cannot reach modules, assignments or files' do
    training_module, mine, = assigned_pair
    file_row = attach(training_module)
    other = Tenant.create!(name: 'Other LMS', subdomain: "lms#{SecureRandom.hex(3)}")
    outsider = User.create!(tenant: other, email: 'lms-outsider@example.com', role: 'admin', password: 'password123')
    sign_in outsider
    get training_modules_path
    assert_response :success
    assert_not_includes response.body, 'Safety walk'
    get training_module_path(training_module)
    assert_response :not_found
    get training_module_attachment_path(training_module, file_row)
    assert_response :not_found
    post training_module_assignments_path(training_module), params: { assignee_ids: [outsider.id] }
    assert_response :not_found
    post cancel_training_assignment_path(mine)
    assert_response :not_found
    get employee_training_path(mine)
    assert_response :not_found
    assert_equal 'assigned', mine.reload.status

    # A foreign person cannot be assigned into this workspace either.
    sign_in @manager
    post training_module_assignments_path(training_module), params: { assignee_ids: [outsider.id] }
    assert_equal 'Choose at least one person, a role or a department.', flash[:alert]
  end

  private

  def sign_in(user)
    delete logout_path if session_signed_in?
    post login_path, params: { email: user.email, password: 'password123' }
  end

  def session_signed_in? = cookies.to_hash.any?

  def file(bytes, name)
    Rack::Test::UploadedFile.new(StringIO.new(bytes.b), 'application/octet-stream', original_filename: name)
  end

  def assigned_pair
    Current.tenant = @tenant
    training_module = TrainingModule.create!(title: 'Safety walk', body: 'Walk the floor.')
    created, = TrainingAssignment.assign!(training_module, [@staff, @coworker], due_on: nil, actor: @manager)
    Current.reset
    [training_module, *created]
  end

  def attach(training_module)
    Current.tenant = @tenant
    TrainingAttachment.from_upload(training_module, file('%PDF-1.4 x', 'x.pdf'), @manager).tap(&:save!)
  ensure
    Current.reset
  end
end
