# frozen_string_literal: true

require 'test_helper'

class WorkTeamToolsTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @token = TeamChat::Token.new(@user)
  end

  teardown { Current.reset }

  def projects(args = {}, token = @token) = Mcp::Tools::ListProjects.new(token: token).call(args)
  def schedule(args = {}, token = @token) = Mcp::Tools::StaffSchedule.new(token: token).call(args)

  def person(email, role: 'reader')
    User.create!(tenant: @tenant, email: email, password: 'password123', role: role, name: email.split('@').first.titleize)
  end

  def shift(employee, day, start_hour, end_hour, role: nil)
    People::ScheduledShift.create!(employee: employee, starts_at: day.in_time_zone + start_hour.hours,
      ends_at: day.in_time_zone + end_hour.hours, role_label: role)
  end

  test 'list_projects shows status, people, task counts and the linked goal' do
    goal = Goals::Goal.create!(name: 'Wholesale growth', target_value: 100, current_value: 40, unit: 'accounts', due_on: Date.current + 60)
    member = person('pat-member@example.invalid')
    project = Projects::Project.create!(name: 'Fall launch', owner_id: @user.id.to_s, due_on: Date.current + 10, goal: goal)
    project.start!
    Projects::ProjectMember.create!(project: project, user: member)
    Projects::Task.create!(title: 'Print labels', project: project, due_on: Date.current - 2)
    Projects::Task.create!(title: 'Photograph tins', project: project).update_columns(status: 'done')
    Projects::Task.create!(title: 'Unrelated', priority: 'low')
    Projects::Project.create!(name: 'Old idea').archive!

    outcome = projects
    row = outcome.data[:rows].sole
    assert_equal ['Fall launch', 'active', @user.display_name, ['Pat Member']], row.values_at(:name, :status, :owner, :members)
    assert_equal({ total: 2, open: 1, todo: 1, in_progress: 0, blocked: 0, done: 1, overdue: 1 }, row[:tasks])
    assert_equal [50, 'at_risk', 'Wholesale growth'], [row[:progress_percent], row[:health], row[:goal][:name]]
    assert_match(/Fall launch \[active, 1\/2 tasks done, 1 overdue/, outcome.text)
    assert_equal 2, projects('status' => 'all').data[:rows].size
    assert_empty projects('query' => 'nothing like this').data[:rows]
    assert_raises(Mcp::ToolError) { projects('status' => 'achieved') }

    detail = projects('project_id' => project.id)
    assert_equal ['Print labels', 'Photograph tins'], detail.data[:tasks].map { |task| task[:title] }
    assert detail.data[:tasks].first[:overdue]
    assert_match(/Unfinished: #\d+ Print labels/, detail.text)
    assert_raises(Mcp::ToolError) { projects('project_id' => 999_999) }

    goals = projects('view' => 'goals')
    assert_equal [40.0, 100.0, 40, ['Fall launch']],
      goals.data[:rows].sole.values_at(:current_value, :target_value, :progress_percent).push(goals.data[:rows].sole[:projects].map { |p| p[:name] })
    assert_match(%r{Wholesale growth \[active, 40/100 accounts \(40%\)}, goals.text)
  end

  test 'list_projects needs projects.read' do
    reader = person('no-projects@example.invalid')
    reader.update_permission_overrides!(['timesheets.read'])
    assert_not Mcp::Tools::ListProjects.available_to?(TeamChat::Token.new(reader))
    assert Mcp::Tools::ListProjects.available_to?(@token)
  end

  test 'staff_schedule lists who is scheduled each day, empty days and hours per person' do
    today = Date.current
    ann = People::Employee.create!(first_name: 'Ann', last_name: 'Opener', email: 'ann@example.invalid', phone: '555-0100')
    bob = People::Employee.create!(first_name: 'Bob', last_name: 'Closer')
    shift(ann, today + 1, 9, 13, role: 'Counter')
    shift(bob, today + 1, 13, 18)
    shift(ann, today + 3, 9, 17)
    shift(bob, today + 10, 9, 17)
    People::LeaveRequest.create!(employee: bob, leave_type: 'vacation', starts_on: today + 3, ends_on: today + 4).approve!

    outcome = schedule
    data = outcome.data
    assert_equal [today.iso8601, (today + 6).iso8601, 'all staff'], data.values_at(:from, :to, :scope)
    assert_equal({ shifts: 3, people: 2, scheduled_hours: 17.0 }, data[:totals])
    tomorrow = data[:days].find { |day| day[:date] == (today + 1).iso8601 }
    assert_equal [['Ann Opener', 'Counter', 4.0], ['Bob Closer', nil, 5.0]], tomorrow[:shifts].map { |s| s.values_at(:employee, :role, :hours) }
    assert_empty data[:days].find { |day| day[:date] == (today + 2).iso8601 }[:shifts]
    assert_equal ['Bob Closer'], data[:days].find { |day| day[:date] == (today + 3).iso8601 }[:on_leave]
    assert_equal [['Ann Opener', 12.0], ['Bob Closer', 5.0]], data[:people].map { |p| p.values_at(:employee, :scheduled_hours) }
    assert_match(/3 shifts, 2 people, 17.0 h scheduled/, outcome.text)
    assert_match(/nobody scheduled/, outcome.text)
    assert_no_match(/555-0100|ann@example/, data.to_json)

    only_bob = schedule('employee' => 'bob', 'from' => (today + 1).iso8601, 'to' => (today + 10).iso8601)
    assert_equal({ shifts: 2, people: 1, scheduled_hours: 13.0 }, only_bob.data[:totals])
    assert_raises(Mcp::ToolError) { schedule('from' => today.iso8601, 'to' => (today + 40).iso8601) }

    staff = schedule('view' => 'staff')
    assert_equal [['Bob Closer', 5.0], ['Ann Opener', 12.0]].sort, staff.data[:rows].map { |r| r.values_at(:name, :scheduled_hours_in_range) }.sort
    assert_match(/2 current staff \(all staff\)/, staff.text)
    assert_no_match(/555-0100|ann@example/, staff.data.to_json)
  end

  test 'staff_schedule shows only their own shifts to staff who cannot review time' do
    viewer = person('own-shifts@example.invalid')
    viewer.update_permission_overrides!(['timesheets.read'])
    own = People::Employee.create!(first_name: 'Own', last_name: 'Shifter', user: viewer)
    other = People::Employee.create!(first_name: 'PRIVATE', last_name: 'COWORKER')
    shift(own, Date.current + 1, 9, 12)
    shift(other, Date.current + 1, 12, 17)
    token = TeamChat::Token.new(viewer)
    assert Mcp::Tools::StaffSchedule.available_to?(token)

    data = schedule({}, token).data
    assert_equal ['own shifts only', 1], [data[:scope], data[:totals][:shifts]]
    assert_no_match(/PRIVATE/, data.to_json)
    assert_equal ['Own Shifter'], schedule({ 'view' => 'staff' }, token).data[:rows].map { |row| row[:name] }

    nobody = person('no-time@example.invalid')
    nobody.update_permission_overrides!(['projects.read'])
    assert_not Mcp::Tools::StaffSchedule.available_to?(TeamChat::Token.new(nobody))
  end
end
