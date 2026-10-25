# frozen_string_literal: true

require 'test_helper'

# #406: assistant-submitted requests wait in a queue until a reviewer approves,
# merges or rejects them; the requester sees the decision.
class AssistantRequestTriageTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @admin.update!(password: 'password123')
    @manager = User.create!(email: 'manager-406@example.com', password: 'password123', role: 'manager', tenant_id: @tenant.id, name: 'Morgan Manager')
    @cashier = User.create!(email: 'cashier-406@example.com', password: 'password123', role: 'cashier', tenant_id: @tenant.id, name: 'Casey Cashier')
    @other_tenant = Tenant.create!(name: 'Other', subdomain: 'other-406')
    @outsider = User.create!(email: 'outsider-406@example.com', password: 'password123', role: 'admin', tenant_id: @other_tenant.id)
    @req = AgentFeedback.create!(source: 'agent', api_access_token_id: 'team-chat', user: @cashier, kind: 'request',
      summary: 'Show reorder points on stock', details: 'I want the reorder point beside each product.',
      conversation_kind: 'team_chat', conversation_id: 7, conversation_message_id: 42, conversation_url: '/chat/general?message=42',
      created_at: Time.zone.local(2026, 10, 20, 9, 30))
  end

  teardown { Current.reset }

  def last_log = ActivityLog.unscoped.order(:id).last

  test 'a reviewer sees the queue and approves a request into a task that keeps requester, date and text' do
    sign_in(@manager)
    get projects_requests_path
    assert_response :success
    assert_select 'h1', 'Requests'
    assert_select "##{ActionView::RecordIdentifier.dom_id(@req)}", text: /Show reorder points on stock/
    assert_select 'a[href=?]', '/chat/general?message=42', text: 'Open chat'

    assert_difference('Projects::Task.count', 1) do
      post accept_projects_request_path(@req), params: { decision: { title: 'Reorder points on stock', priority: 'high', assignee_id: @manager.id } }
    end
    assert_redirected_to projects_requests_path
    @req.reload
    task = @req.task
    assert_equal 'accepted', @req.triage_decision
    assert_equal 'planned', @req.status
    assert_equal @manager.id, @req.triaged_by_id
    assert_equal 'Reorder points on stock', task.title
    assert_equal 'high', task.priority
    assert_equal @manager.id.to_s, task.assignee_id
    assert_equal FeedbackTask::PROJECT_NAME, task.project.name
    assert_includes task.description, 'I want the reorder point beside each product.'
    assert_includes task.description, "Requested by #{@cashier.display_name} on October 20, 2026 via Team chat /chat/general?message=42"
    assert_includes task.description, "/feedback_reports/#{@req.id}"
    assert_equal [@req.id], task.source_requests.pluck(:id)
    assert_equal 'assistant_request_accepted', last_log.action
    assert_equal @req.id.to_s, last_log.subject_id

    get projects_task_path(task)
    assert_select '#requests', text: /Show reorder points on stock/

    get projects_requests_path
    assert_select "##{ActionView::RecordIdentifier.dom_id(@req)}", count: 0
    assert_select "##{ActionView::RecordIdentifier.dom_id(@req, :decided)}", text: /Approved/

    assert_no_difference('Projects::Task.count') { post accept_projects_request_path(@req) }
    assert_match(/already approved/, flash[:alert])
  end

  test 'a request already decided cannot be decided again' do
    RequestTriage.decline!(request: @req, user: @admin, params: { reason: 'Not now' })
    assert_raises(RequestTriage::Error) { RequestTriage.accept!(request: @req.reload, user: @admin) }
    assert_equal 'declined', @req.reload.triage_decision
  end

  test 'merging links a duplicate to an existing task and records the request on it' do
    existing = Projects::Task.create!(title: 'Reorder points', priority: 'medium')
    sign_in(@manager)
    assert_no_difference('Projects::Task.count') do
      assert_difference('Projects::TaskComment.count', 1) do
        post merge_projects_request_path(@req), params: { decision: { task_id: existing.id } }
      end
    end
    @req.reload
    assert_equal 'merged', @req.triage_decision
    assert_equal existing.id, @req.task_id
    comment = existing.comments.last
    assert_includes comment.body, 'Duplicate request merged here.'
    assert_includes comment.body, @cashier.display_name
    assert_equal 'assistant_request_merged', last_log.action
    assert ActivityLog.unscoped.exists?(action: 'request_merged_into_task', subject_id: existing.id.to_s)
  end

  test 'merging needs a task in this workspace' do
    Current.tenant = @other_tenant
    foreign = Projects::Task.create!(title: 'Elsewhere', priority: 'medium')
    Current.tenant = @tenant
    sign_in(@manager)
    post merge_projects_request_path(@req), params: { decision: { task_id: foreign.id } }
    assert_equal 'Choose the task this request duplicates.', flash[:alert]
    assert_nil @req.reload.triage_decision
  end

  test 'rejecting needs a reason, which the requester reads' do
    sign_in(@manager)
    post decline_projects_request_path(@req), params: { decision: { reason: '' } }
    assert_match(/Say why/, flash[:alert])
    assert_nil @req.reload.triage_decision

    post decline_projects_request_path(@req), params: { decision: { reason: 'Stock already shows reorder points under More.' } }
    @req.reload
    assert_equal 'declined', @req.triage_decision
    assert_equal 'wont_fix', @req.status
    assert_nil @req.task_id
    assert_equal 'assistant_request_declined', last_log.action
    assert_includes last_log.details, 'reason=Stock already shows'

    delete logout_path
    sign_in(@cashier)
    get feedback_reports_path
    assert_select 'span.pill-taupe', 'Rejected'
    get feedback_report_path(@req)
    assert_select '[data-request-decision]', text: /Stock already shows reorder points under More\./
    assert_select '[data-request-decision]', text: /Morgan Manager/
  end

  test 'the requester sees the request in review, then approved' do
    sign_in(@cashier)
    get feedback_reports_path
    assert_select 'span.pill-clay', 'In review'
    get feedback_report_path(@req)
    assert_select '[data-request-decision]', text: /Waiting for a reviewer/

    RequestTriage.accept!(request: @req, user: @admin)
    get feedback_report_path(@req)
    assert_select '[data-request-decision]', text: /Approved/
    # A cashier cannot open the task, so no link is offered.
    assert_select "[data-request-decision] a[href='#{projects_task_path(@req.reload.task_id)}']", count: 0
  end

  test 'people without task write permission cannot open or work the queue' do
    sign_in(@cashier)
    get projects_requests_path
    assert_redirected_to root_path
    post accept_projects_request_path(@req)
    post decline_projects_request_path(@req), params: { decision: { reason: 'no' } }
    assert_nil @req.reload.triage_decision
    assert_raises(RequestTriage::Denied) { RequestTriage.accept!(request: @req, user: @cashier) }
  end

  test 'another workspace never sees or decides these requests' do
    sign_in(@outsider)
    get projects_requests_path
    assert_response :success
    assert_select 'body', text: /Show reorder points on stock/, count: 0
    post decline_projects_request_path(@req), params: { decision: { reason: 'Not ours' } }
    assert_response :not_found
    assert_nil AgentFeedback.unscoped.find(@req.id).triage_decision
  end

  test 'a chat link is only ever a path inside Rupert' do
    %w[https://evil.example //evil.example /\\evil.example javascript:alert(1)].each do |url|
      assert_not AgentFeedback.new(kind: 'request', summary: 's', source: 'agent', conversation_url: url).valid?, url
    end
  end

  test 'only assistant requests are queued: bugs and ladybug requests are not' do
    AgentFeedback.create!(source: 'agent', kind: 'bug', summary: 'Broken total')
    AgentFeedback.create!(source: 'app', user: @cashier, kind: 'request', summary: 'Ladybug request')
    assert_equal [@req.id], AgentFeedback.awaiting_triage.pluck(:id)
  end

  test 'an Ask Rupert request goes to the queue instead of opening a task' do
    conversation = AskRupert::Conversation.create!(user: @cashier, tenant_id: @tenant.id)
    feedback = nil
    assert_no_difference('Projects::Task.count') do
      feedback = AskRupert::Reporter.file!(user: @cashier, conversation: conversation, kind: 'request', summary: 'Add a dark mode for the till')
    end
    assert_equal 'ask_rupert', feedback.conversation_kind
    assert_equal conversation.id, feedback.conversation_id
    assert_includes AgentFeedback.awaiting_triage, feedback
  end

  test 'an assistant request over MCP waits for review unless an allow-listed sender marked it ready' do
    outcome = nil
    assert_no_difference('Projects::Task.count') do
      outcome = FeedbackIntake.file!(source: 'agent', source_ref: 'm-406', source_sender: nil, kind: 'suggestion', summary: 'Group tasks by store', user: @admin)
    end
    assert_nil outcome.task
    assert outcome.feedback.awaiting_triage?
    RequestTriage.accept!(request: outcome.feedback, user: @admin)
    assert_equal 'accepted', outcome.feedback.reload.agent_view[:triage_decision]
  end
end
