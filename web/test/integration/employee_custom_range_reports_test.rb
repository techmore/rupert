# frozen_string_literal: true

require 'test_helper'
require 'csv'

# Issue #457: employees run their own time card report for any start and end date.
class EmployeeCustomRangeReportsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @user = User.create!(tenant: @tenant, email: 'range-worker@example.com', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(first_name: 'Rae', last_name: 'Range', user: @user)
    @other = People::Employee.create!(first_name: 'Other', last_name: 'Person')
    @worker.pay_rates.create!(effective_on: Date.new(2026, 1, 1), hourly_rate_cents: 2000, pay_type: 'hourly')
    september = @worker.timesheets.create!(period_start: Date.new(2026, 9, 24), period_end: Date.new(2026, 9, 30))
    september.entries.create!(worked_on: Date.new(2026, 9, 28), hours: 4, work_type: 'regular', notes: 'SEPT SHIFT')
    october = @worker.timesheets.create!(period_start: Date.new(2026, 10, 1), period_end: Date.new(2026, 10, 7))
    october.entries.create!(worked_on: Date.new(2026, 10, 2), hours: 6, work_type: 'regular', notes: 'OCT SHIFT')
    october.entries.create!(worked_on: Date.new(2026, 10, 7), hours: 2, work_type: 'regular', notes: 'LATE OCT SHIFT')
    other_sheet = @other.timesheets.create!(period_start: Date.new(2026, 10, 1), period_end: Date.new(2026, 10, 7))
    other_sheet.entries.create!(worked_on: Date.new(2026, 10, 2), hours: 9, work_type: 'regular', notes: 'OTHER PRIVATE SHIFT')
    post login_path, params: { email: @user.email, password: 'password123' }
    Current.tenant = @tenant
  end
  teardown { Current.reset }

  test 'custom range spanning two time cards shows only matching entries and totals' do
    get employee_reports_path, params: { range: 'custom', from: '2026-09-28', to: '2026-10-02', range_shown: '2026-10-19..2026-10-25' }
    assert_response :success
    assert_select 'input[name="from"][value="2026-09-28"]'
    assert_select 'input[name="to"][value="2026-10-02"]'
    assert_select '.stat-value', text: '10h'
    assert_select '.stat-value', text: '$200.00'
    assert_includes response.body, 'Sep 28 – Oct 2, 2026'
    assert_includes response.body, I18n.l(Date.new(2026, 10, 2), format: :long)
    refute_includes response.body, I18n.l(Date.new(2026, 10, 7), format: :long)
  end

  test 'csv export covers the custom range with a total row and only own entries' do
    get employee_reports_path(format: :csv), params: { from: '2026-09-28', to: '2026-10-07', employee_id: @other.id }
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal ['SEPT SHIFT', 'OCT SHIFT', 'LATE OCT SHIFT', nil], rows.map { |row| row['Notes'] }
    total = rows.to_a.last
    assert_equal 'Total 2026-09-28 to 2026-10-07', total[0]
    assert_equal '12.0', total[3]
    assert_equal '240.00', total[4]
    refute_includes response.body, 'OTHER PRIVATE SHIFT'
  end

  test 'reversed, oversized and malformed ranges are rejected on the page with the reason' do
    get employee_reports_path, params: { from: '2026-10-07', to: '2026-10-01' }
    assert_response :unprocessable_entity
    assert_select '[role="alert"].flash-alert', text: /end date \(Oct 1, 2026\) is before the start date \(Oct 7, 2026\)/
    refute_includes response.body, I18n.l(Date.new(2026, 10, 2), format: :long)

    get employee_reports_path, params: { from: '2025-01-01', to: '2026-01-02' }
    assert_response :unprocessable_entity
    assert_select '[role="alert"].flash-alert', text: /up to one year/

    get employee_reports_path, params: { from: '2026-02-30', to: '2026-03-01' }
    assert_response :unprocessable_entity
    assert_select '[role="alert"].flash-alert', text: /real calendar dates/

    get employee_reports_path(format: :csv), params: { from: '2026-10-07', to: '2026-10-01' }
    assert_response :unprocessable_entity
    refute_includes response.body, 'OCT SHIFT'
  end

  test 'a full year counting both ends is allowed' do
    get employee_reports_path, params: { from: '2025-10-08', to: '2026-10-07' }
    assert_response :success
    assert_select '.stat-value', text: '12h'
  end

  test 'preset day boundaries follow the business time zone, not UTC' do
    # 02:00 UTC on Oct 3 is still Oct 2 in the business time zone (Eastern).
    travel_to Time.utc(2026, 10, 3, 2, 0) do
      get employee_reports_path, params: { range: 'today' }
      assert_response :success
      assert_select 'input[name="from"][value="2026-10-02"]'
      assert_select '.stat-value', text: '6h'
    end
  end

  test 'the employee sees only their own time card' do
    get employee_reports_path, params: { from: '2026-10-01', to: '2026-10-07', employee_id: @other.id, worker_id: @other.id }
    assert_response :success
    refute_includes response.body, 'OTHER PRIVATE SHIFT'
    assert_select '.stat-value', text: '8h'
    # The management time keeping report keeps its existing rule: non-reviewers see only themselves.
    get people_time_keeping_path, params: { from: '2026-10-01', to: '2026-10-07', employee_id: @other.id }
    refute_includes response.body, 'Other Person'
  end
end
