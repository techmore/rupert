# frozen_string_literal: true

require 'test_helper'

# Training assignments on the shared work-item table (#407 phase 2b, #409): the registered kind, history in
# work_item_events, the Activity log names, due dates on the shared calendar by permission, old assignment links,
# and the leak audit — training rows never show up as tasks, in task counts, task tools or the task export.
class TrainingWorkItemsTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.parse('2026-11-04 12:00')
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @hr_viewer = User.create!(tenant: @tenant, email: 'twi-manager@example.com', role: 'manager', password: 'password123')
    # Tasks access but no staff (hr) access.
    @reporter = User.create!(tenant: @tenant, email: 'twi-reporting@example.com', role: 'reporting', password: 'password123')
    %w[dashboard.read projects.read].each { |key| @reporter.user_permissions.create!(permission: key, enabled: true, tenant_id: @tenant.id) }
    @staff = User.create!(tenant: @tenant, email: 'twi-staff@example.com', name: 'Sam Staff', role: 'employee', password: 'password123')
    @module = TrainingModule.create!(title: 'Till safety', body: 'Count twice.')
    @staff_item, @reporter_item = TrainingAssignment.assign!(@module, [@staff, @reporter], due_on: Date.new(2026, 11, 12), actor: @admin).first
    @task = Projects::Task.create!(title: 'Order receipt rolls', due_on: Date.new(2026, 11, 10))
    other = Tenant.create!(name: 'Training other', subdomain: "twi#{SecureRandom.hex(3)}")
    other_admin = User.create!(tenant: other, email: 'twi-other@example.com', role: 'admin', password: 'password123')
    Current.tenant = other
    other_module = TrainingModule.create!(title: 'Their induction')
    TrainingAssignment.assign!(other_module, [other_admin], due_on: Date.new(2026, 11, 12), actor: other_admin)
    Current.reset
  end

  teardown { Current.reset }

  def sign_in(user, password = 'password123')
    delete logout_path if cookies.to_hash.any?
    post login_path, params: { email: user.email, password: password }
  end

  test 'the training kind is registered with the old transitions, permissions and policy' do
    kind = Work::Registry.fetch('training_assignment')
    assert_equal %w[assigned in_progress completed cancelled], kind.statuses
    assert_equal 'assigned', kind.initial_status
    assert_equal({ 'start' => [%w[assigned], 'in_progress', :assignee_only], 'complete' => [%w[in_progress], 'completed', :assignee_only],
                   'cancel' => [%w[assigned in_progress], 'cancelled', :manager] },
      kind.transition_table.transform_values { |spec| [spec[:from], spec[:to], spec[:who]] })
    assert_equal({ read: 'hr.read', write: 'hr.write' }, kind.permissions)
    assert_equal Training::AssignmentPolicy, kind.policy_class
    assert_equal :due, kind.calendar
  end

  test 'an assignment is a shared work item with its history and the training Activity log names' do
    Current.tenant = @tenant
    item = Work::Item.find(@staff_item.id)
    assert_equal ['training_assignment', 'assigned', @staff.id.to_s, @admin.id.to_s, 'TrainingModule', @module.id, 'Till safety'],
      [item.kind, item.status, item.assignee_id, item.requester_id, item.source_type, item.source_id, item.title]

    @staff_item.transition!('start', actor: @staff)
    @module.update!(body: 'Count three times.')
    @staff_item.transition!('complete', actor: @staff)
    @reporter_item.transition!('cancel', actor: @admin, note: 'Left the team')

    history = Work::ItemEvent.where(work_item_id: @staff_item.id).timeline.to_a
    assert_equal [%w[created assigned], %w[transitioned in_progress], %w[transitioned completed]], history.map { |row| [row.action, row.to_status] }
    assert_equal [nil, 'start', 'complete'], history.map(&:transition)
    assert_equal [1, 1, 2], history.map { |row| row.details['module_revision'] }
    assert_equal({ 'completed_revision' => 2, 'completed_by_id' => @staff.id }, @staff_item.reload.details)
    assert @staff_item.completed_at
    assert_equal 'Left the team', @reporter_item.events.last.note
    assert @reporter_item.reload.cancelled_at

    logs = ActivityLog.unscoped.where(tenant_id: @tenant.id).where('action LIKE ?', 'training%').order(:id)
    assert_equal %w[training_started training_completed training_assignment_cancelled], logs.map(&:action)
    assert_equal ['TrainingModule'], logs.map(&:subject_type).uniq
    assert_not ActivityLog.unscoped.exists?(action: 'training_transitioned')

    # Status still changes only through a transition, and a manager cannot train on someone's behalf.
    item = Work::Item.find(@staff_item.id)
    item.status = 'assigned'
    assert_not item.save
    fresh = TrainingAssignment.assign!(@module, [@staff], due_on: nil, actor: @admin).first.sole
    assert_raises(Work::Item::TransitionRefused) { Work::Item.find(fresh.id).transition!('start', user: @admin) }
    assert_not fresh.destroy
  end

  test 'policy scope: hr.read sees every assignment, everyone else only their own, other workspaces nothing' do
    Current.tenant = @tenant
    kind = Work::Registry.fetch('training_assignment')
    all_ids = [@staff_item.id, @reporter_item.id].sort
    assert_equal all_ids, kind.visible_to(@admin, Work::Item.all).pluck(:id).sort
    assert_equal all_ids, kind.visible_to(@hr_viewer, Work::Item.all).pluck(:id).sort
    assert_equal [@reporter_item.id], kind.visible_to(@reporter, Work::Item.all).pluck(:id)
    assert_equal [@staff_item.id], kind.visible_to(@staff, Work::Item.all).pluck(:id)
    assert_not Training::AssignmentPolicy.new(@staff, @reporter_item).show?
    assert Training::AssignmentPolicy.new(@staff, @staff_item).transition?
    assert_not Training::AssignmentPolicy.new(@hr_viewer, @staff_item).transition?
    assert Training::AssignmentPolicy.new(@admin, @staff_item).transition?
    assert_equal 2, TrainingAssignment.count
    # unscoped crosses workspaces but never kinds.
    assert_equal 3, TrainingAssignment.unscoped.count
    assert_equal %w[training_assignment], TrainingAssignment.unscoped.distinct.pluck(:kind)
  end

  test 'the calendar shows training due dates to the people allowed to see them' do
    sign_in(@admin, 'password')
    get calendar_path(month: '2026-11', view: 'agenda')
    assert_response :success
    assert_select "a[href='#{training_module_path(@module, anchor: 'assignments')}']", text: 'Till safety', count: 2
    assert_select 'td', text: 'Training'
    assert_select 'td', text: 'Sam Staff'
    refute_includes response.body, 'Their induction'
    get calendar_path(month: '2026-11', view: 'agenda', show: 'training')
    assert_includes response.body, 'Till safety'
    refute_includes response.body, 'Order receipt rolls'

    # hr.read without tasks access still opens the calendar for training.
    sign_in(@hr_viewer)
    get calendar_path(month: '2026-11', view: 'agenda')
    assert_select 'a', text: 'Till safety', count: 2

    # Without hr.read, only their own assignment, linked to their own training page.
    sign_in(@reporter)
    get calendar_path(month: '2026-11', view: 'agenda')
    assert_response :success
    assert_select "a[href='#{employee_training_path(@reporter_item)}']", text: 'Till safety'
    assert_select 'a', text: 'Till safety', count: 1
    assert_select 'td', text: 'Sam Staff', count: 0

    # Staff stay in their workspace; their training is under Training there.
    sign_in(@staff)
    get calendar_path
    assert_response :redirect
  end

  test 'old assignment links redirect to the new id, only for the assignee' do
    Current.tenant = @tenant
    legacy_id = TrainingAssignment::Legacy.connection.insert(<<~SQL.squish)
      INSERT INTO training_assignments (tenant_id, training_module_id, assignee_id, status, work_item_id, created_at, updated_at)
      VALUES ('#{@tenant.id}', #{@module.id}, #{@staff.id}, 'assigned', #{@staff_item.id}, '2026-10-01 10:00:00', '2026-10-01 10:00:00')
    SQL
    legacy_id += 100_000 while TrainingAssignment.unscoped.exists?(id: legacy_id) # keep the test meaningful if ids collide
    TrainingAssignment::Legacy.connection.update("UPDATE training_assignments SET id = #{legacy_id} WHERE work_item_id = #{@staff_item.id}")
    Current.reset

    sign_in(@staff)
    get employee_training_path(legacy_id)
    assert_redirected_to employee_training_path(@staff_item)
    assert_response :moved_permanently
    post start_employee_training_path(legacy_id)
    assert_response :see_other
    assert_equal 'assigned', @staff_item.reload.status

    sign_in(@reporter)
    get employee_training_path(legacy_id)
    assert_response :not_found

    sign_in(@admin, 'password')
    post cancel_training_assignment_path(legacy_id)
    assert_redirected_to training_module_path(@module, anchor: 'assignments')
    assert_equal 'assigned', @staff_item.reload.status
  end

  test 'training rows never show up as tasks, in task counts, task tools or the task export' do
    Current.tenant = @tenant
    Current.user = @admin
    project = Projects::Project.create!(name: 'Front counter')
    Projects::Task.create!(title: 'Wipe counter', project: project, due_on: Date.new(2026, 11, 1))
    assert_equal 2, Projects::Task.count
    assert_equal [@task.id], Projects::Task.where(title: 'Order receipt rolls').pluck(:id)
    assert_equal 0, Projects::Task.where(kind: 'training_assignment').count
    assert_equal({ 'todo' => 1, 'in_progress' => 0, 'blocked' => 0, 'done' => 0 }, project.reload.task_counts)
    assert_equal 1, Projects::Task.overdue.count
    assert_raises(ActiveRecord::RecordNotFound) { Projects::Task.find(@staff_item.id) }
    assert_equal Projects::Task.pluck(:id).sort, Projects::TaskPolicy::Scope.new(@admin, Work::Item.all).resolve.pluck(:id).sort
    assert_empty Projects::TaskPolicy::Scope.new(@staff, Work::Item.all).resolve.where(kind: 'training_assignment')

    token = TeamChat::Token.new(@admin)
    listed = Mcp::Registry.find('list_tasks').new(token: token).call({}).to_s
    assert_includes listed, 'Order receipt rolls'
    refute_includes listed, 'Till safety'
    error = assert_raises(Mcp::ToolError) { Mcp::Registry.find('update_task').new(token: token).call({ 'task_id' => @staff_item.id, 'title' => 'Hijacked' }) }
    assert_match(/No task/, error.message)
    assert_equal 'Till safety', Work::Item.find(@staff_item.id).title
    Current.reset

    sign_in(@admin, 'password')
    get projects_tasks_path(view: 'list')
    assert_response :success
    refute_includes response.body, 'Till safety'
    get projects_task_path(@staff_item)
    assert_response :not_found
    get export_projects_tasks_path
    assert_includes response.body, 'Order receipt rolls'
    refute_includes response.body, 'Till safety'
    sign_in(@staff)
    get projects_tasks_path
    refute_includes response.body, 'Till safety'
  end
end
