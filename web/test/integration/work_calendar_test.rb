# frozen_string_literal: true

require 'test_helper'

# The shared calendar (#417): task deadlines and marketing events in one month or agenda view, each kind filtered
# by its own permissions, kept to the workspace, with time zone, place, status and a link to each record. Also checks
# that marketing work items never leak into task screens or task tools.
class WorkCalendarTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.parse('2026-11-04 12:00')
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    Current.user = @admin
    FeatureFlag.set(:marketing, true)
    @task = Projects::Task.create!(title: 'File sales tax', due_on: Date.new(2026, 11, 10), priority: 'high')
    @late = Projects::Task.create!(title: 'Overdue restock', due_on: Date.new(2026, 11, 2))
    @event = Work::Item.create!(kind: 'marketing_event', title: 'Tea tasting', assignee_id: @admin.id.to_s,
      details: { 'starts_at' => '2026-11-14T13:00', 'ends_at' => '2026-11-15T17:00', 'time_zone' => 'Pacific Time (US & Canada)',
                 'venue' => 'Main St shop', 'channel' => 'in_store' })
    @work = Work::Item.create!(kind: 'campaign_task', title: 'Order sample cups', parent: @event, due_on: Date.new(2026, 11, 12))
    other = Tenant.create!(name: 'Calendar other', subdomain: 'calendar-other')
    Projects::Task.unscoped.create!(tenant_id: other.id, title: 'Their deadline', due_on: Date.new(2026, 11, 10))
    Work::Item.unscoped.create!(tenant_id: other.id, kind: 'marketing_event', title: 'Their launch',
      details: { 'starts_at' => '2026-11-10T10:00', 'ends_at' => '2026-11-10T11:00', 'time_zone' => 'UTC', 'channel' => 'online' })
    Current.reset
  end

  def sign_in(email, password = 'password')
    post login_path, params: { email: email, password: password }
  end

  test 'an administrator sees task deadlines and marketing events with time zone, place, status and links' do
    sign_in('admin@example.com')
    task_queries = []
    counter = ->(*, payload) { task_queries << payload[:sql] if payload[:sql].match?(/FROM "tasks"/) && !payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get calendar_path(month: '2026-11') }
    assert_response :success
    assert_equal 1, task_queries.size, "one query for every kind in the range:\n#{task_queries.join("\n")}"
    assert_select 'h1', 'Calendar'
    assert_select 'nav[aria-label="Module"] a', text: 'Calendar'
    assert_select "a[href='#{projects_task_path(@task)}']", text: /File sales tax/
    assert_select "a[href='#{marketing_event_path(@event)}']", minimum: 2 # both days of the event
    assert_select "a[href='#{marketing_event_path(@event, anchor: 'event-work')}']", text: /Order sample cups/
    assert_includes response.body, '1:00 PM PST'
    refute_includes response.body, 'Their deadline'
    refute_includes response.body, 'Their launch'

    get calendar_path(month: '2026-11', view: 'agenda')
    assert_select 'td', text: 'Main St shop · In store'
    assert_select 'td', text: /1:00 PM – Nov 15, 5:00 PM PST/
    assert_select '.pill-rose', text: 'Overdue'
    assert_select 'td', text: 'Marketing event'

    get calendar_path(month: '2026-11', view: 'agenda', show: 'tasks')
    assert_includes response.body, 'File sales tax'
    refute_includes response.body, 'Tea tasting'

    get calendar_path(month: '2026-12', view: 'agenda')
    assert_select '.empty-state'
  end

  test 'the calendar shows each person only the kinds they may see' do
    manager = User.create!(tenant: @tenant, email: 'calendar-manager@example.com', role: 'manager', password: 'password123')
    sign_in(manager.email, 'password123')
    get calendar_path(month: '2026-11', view: 'agenda')
    assert_response :success
    assert_includes response.body, 'File sales tax'
    refute_includes response.body, 'Tea tasting'
    refute_includes response.body, 'Order sample cups'

    delete logout_path
    Current.tenant = @tenant
    FeatureFlag.set(:marketing, false)
    sign_in('admin@example.com')
    get calendar_path(month: '2026-11', view: 'agenda')
    assert_includes response.body, 'File sales tax'
    refute_includes response.body, 'Tea tasting', 'Marketing off hides events'
  end

  test 'people with neither tasks nor marketing cannot open the calendar, and staff stay in their workspace' do
    cashier = User.create!(tenant: @tenant, email: 'calendar-cashier@example.com', role: 'cashier', password: 'password123')
    sign_in(cashier.email, 'password123')
    get calendar_path
    refute response.successful?
    delete logout_path
    staff = User.create!(tenant: @tenant, email: 'calendar-staff@example.com', role: 'employee', password: 'password123')
    sign_in(staff.email, 'password123')
    get calendar_path
    assert_response :redirect
  end

  test 'marketing items do not change task screens, task counts or task tools' do
    sign_in('admin@example.com')
    get projects_tasks_path(view: 'list')
    assert_response :success
    refute_includes response.body, 'Tea tasting'
    refute_includes response.body, 'Order sample cups'
    get projects_tasks_path(view: 'calendar', month: '2026-11')
    refute_includes response.body, 'Tea tasting'
    get projects_task_path(@event)
    assert_response :not_found

    Current.tenant = @tenant
    Current.user = @admin
    token = TeamChat::Token.new(@admin)
    titles = Mcp::Registry.find('list_tasks').new(token: token).call({}).to_s
    refute_includes titles.to_s, 'Tea tasting'
    refute_includes titles.to_s, 'Order sample cups'
    assert_includes titles.to_s, 'File sales tax'
    error = assert_raises(Mcp::ToolError) do
      Mcp::Registry.find('update_task').new(token: token).call({ 'task_id' => @event.id, 'title' => 'Hijacked' })
    end
    assert_match(/No task/, error.message)
    assert_equal 'Tea tasting', Work::Item.find(@event.id).title
  ensure
    Current.reset
  end
end
