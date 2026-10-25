# frozen_string_literal: true

require 'test_helper'
require_relative 'walkthrough_helper'

# #411: the LMS flow with synthetic people and content through the real pages. A manager writes a module with a file
# and a video link and assigns it to two staff members. One starts, signs out and back in (progress recovered), opens
# the file and the video link, and completes it; the other starts and is cancelled. The module page, history, staff
# pages and the first-week checklist reflect it, and role and workspace boundaries hold. Backup recovery of the file is
# a database copy, so it is checked outside this transactional test (see the #411 evidence comment).
class TrainingWalkthroughTest < ActionDispatch::IntegrationTest
  include WalkthroughHelper

  PDF = "%PDF-1.4\n% synthetic register guide\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n"

  setup do
    synthetic_workspace('Walkthrough training')
    @manager, = person('lms-walk-manager@example.test', 'admin', 'Mona', 'Manager')
    @sam, = person('lms-walk-sam@example.test', 'employee', 'Sam', 'Staff')
    @casey, = person('lms-walk-casey@example.test', 'employee', 'Casey', 'Clerk')
    Current.reset
  end

  test 'manager builds and assigns a module; one trainee completes, one is cancelled' do
    sign_in(@manager)
    item = checklist(@manager, 'training_module')
    assert_equal [true, false], [item.present?, item&.done?]
    step 'Manager first-week checklist', '"Configure, assign and complete a training module" shown, not done'

    post training_modules_path, params: { training_module: { title: 'Opening the register', body: "Count the float.\n\nSign the sheet.", video_url: 'https://videos.example.test/opening' } }
    mod = tenant_scope { TrainingModule.find_by!(title: 'Opening the register') }
    assert_redirected_to training_module_path(mod)
    post training_module_attachments_path(mod), params: { file: upload(PDF, 'register-guide.pdf') }
    assert_equal 'File added.', flash[:notice]
    post training_module_attachments_path(mod), params: { file: upload("Float: $150\n", 'float.txt') }
    post training_module_attachments_path(mod), params: { file: upload("\x00\x00\x00\x18ftypmp42".b, 'opening.mp4') }
    assert flash[:alert].present?
    files = tenant_scope { mod.attachments.order(:id).map { |f| [f.filename, f.byte_size, f.sha256] } }
    assert_equal %w[register-guide.pdf float.txt], files.map(&:first)
    assert_equal Digest::SHA256.hexdigest(PDF), files.first.last
    assert_equal 3, tenant_scope { mod.reload.revision }
    step 'Manager adds the module (text + https video link), a PDF and a TXT; tries an MP4',
      "2 files stored (#{files.map { |f| "#{f[0]} #{f[1]} B" }.join(', ')}), MP4 refused (video is a link), revision 3"

    due = Date.current + 7
    post training_module_assignments_path(mod), params: { assignee_ids: [@sam.id, @casey.id], due_on: due.iso8601 }
    assert_equal 'Assigned to 2 people.', flash[:notice]
    post training_module_assignments_path(mod), params: { assignee_ids: [@sam.id] }
    assert_equal 'Assigned to 0 people. 1 person already had it open.', flash[:notice]
    sam_a, casey_a = tenant_scope { [@sam, @casey].map { |u| TrainingAssignment.find_by!(assignee_id: u.id) } }
    step 'Assign to Sam and Casey, due in 7 days; assign Sam again', "2 assignments (due #{due.iso8601}); the repeat is skipped"

    # Sam starts, signs out, comes back: progress is still there.
    sign_in(@sam)
    get employee_training_index_path
    assert_select "[data-assignment-id='#{sam_a.id}']"
    assert_select "[data-assignment-id='#{casey_a.id}']", count: 0
    get employee_training_path(sam_a)
    assert_select 'a[href="https://videos.example.test/opening"][target="_blank"][rel~="noopener"]', text: 'Open video'
    post complete_employee_training_path(sam_a)
    assert_match(/Cannot complete/, flash[:alert])
    post start_employee_training_path(sam_a)
    assert_equal 'Training started. Mark it complete when you have finished.', flash[:notice]
    delete logout_path
    sign_in(@sam)
    get employee_training_path(sam_a)
    assert_select 'dd', text: /In progress/
    pdf_id = tenant_scope { mod.attachments.find_by!(filename: 'register-guide.pdf').id }
    get employee_training_file_path(sam_a, pdf_id)
    assert_equal [PDF.b, 'application/pdf'], [response.body.b, response.media_type]
    get employee_training_path(casey_a)
    assert_response :not_found
    get training_modules_path
    assert_response :redirect
    step "Sam: list shows only Sam's assignment; video is a new-tab link; complete-before-start refused; start; sign out and back in",
      'still In progress after the new session; PDF downloads byte-identical; Casey\'s assignment 404; manager pages redirect'

    post complete_employee_training_path(sam_a)
    assert_equal 'Training complete. Your manager can see it.', flash[:notice]
    tenant_scope { sam_a.reload }
    assert_equal ['completed', @sam.id, 3], [sam_a.status, sam_a.completed_by_id, sam_a.completed_revision]
    post start_employee_training_path(sam_a)
    assert flash[:alert].present?
    assert checklist(@sam, 'my_training').done?
    step 'Sam marks it complete; tries to start again', 'completed by Sam at revision 3; restart refused; "Complete your assigned training" ticked'

    # Casey starts; the manager cancels.
    sign_in(@casey)
    post start_employee_training_path(casey_a)
    sign_in(@manager)
    post cancel_training_assignment_path(casey_a), params: { note: 'Moved to the warehouse team' }
    assert_equal 'Assignment cancelled.', flash[:notice]
    sign_in(@casey)
    get employee_training_index_path
    assert_select "[data-assignment-id='#{casey_a.id}']", count: 0
    post complete_employee_training_path(casey_a)
    assert_response :not_found
    get employee_training_file_path(casey_a, pdf_id)
    assert_response :not_found
    assert_nil checklist(@casey, 'my_training')
    step 'Casey starts; manager cancels with a note; Casey tries to complete and download',
      'cancelled; gone from her list; complete and file 404; no open-training checklist item'

    # Manager view: assignments, history, stats, checklist.
    sign_in(@manager)
    get training_module_path(mod)
    assert_response :success
    assert_select "tr[data-assignment-id='#{sam_a.id}']", text: /Completed/
    assert_select "tr[data-assignment-id='#{casey_a.id}']", text: /Cancelled/
    assert_select '#history li', count: 6
    history = tenant_scope { TrainingAssignmentEvent.where(training_assignment_id: [sam_a.id, casey_a.id]).order(:id).map { |e| [e.actor_name, e.action, e.module_revision] } }
    assert_equal [%w[assigned assigned started started completed cancelled].sort, 6], [history.map(&:second).sort, history.size]
    get training_modules_path
    assert_response :success
    assert checklist(@manager, 'training_module').done?
    logs = tenant_scope { ActivityLog.where(tenant_id: @tenant.id).where('action LIKE ?', 'training%').order(:id).pluck(:action) }
    step 'Manager module page and history',
      "Sam Completed, Casey Cancelled; history #{history.map { |n, a, r| "#{n}: #{a} (rev #{r})" }.join('; ')}; checklist item ticked; activity log #{logs.tally.map { |k, v| "#{k}×#{v}" }.join(', ')}"

    # Editing after completion raises the revision; the completion keeps the revision it was done at.
    patch training_module_path(mod), params: { training_module: { title: 'Opening the register', body: "Count the float twice.\n\nSign the sheet.", video_url: 'https://videos.example.test/opening' } }
    assert_equal [4, 3], tenant_scope { [mod.reload.revision, sam_a.reload.completed_revision] }
    step 'Manager edits the text after completion', 'module revision 4; Sam\'s completion still records revision 3'

    # Another workspace.
    other = Tenant.create!(name: 'Walkthrough outsider', subdomain: "walkout#{SecureRandom.hex(3)}")
    outsider = User.create!(tenant: other, email: 'lms-walk-outsider@example.test', role: 'admin', password: PASSWORD)
    delete logout_path
    post login_path, params: { email: outsider.email, password: PASSWORD }
    get training_modules_path
    assert_not_includes response.body, 'Opening the register'
    [training_module_path(mod), training_module_attachment_path(mod, pdf_id), employee_training_path(sam_a)].each do |path|
      get path
      assert_response :not_found
    end
    post cancel_training_assignment_path(sam_a)
    assert_response :not_found
    step 'Admin of another workspace', 'module not listed; module, file, assignment and cancel all 404'
  end

  private

  def upload(bytes, name)
    Rack::Test::UploadedFile.new(StringIO.new(bytes.b), 'application/octet-stream', original_filename: name)
  end

  def checklist(user, key)
    tenant_scope { GettingStartedChecklist.new(user.reload).items.find { |item| item.key == key } }
  end
end
