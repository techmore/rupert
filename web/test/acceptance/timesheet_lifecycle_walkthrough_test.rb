# frozen_string_literal: true

require 'test_helper'
require_relative 'walkthrough_helper'

# #422: a complete synthetic timesheet lifecycle through the real routes. A staff member clocks in and out from the
# staff app (with a retried clock-in), asks for a clock correction that the owner approves (and one that is rejected),
# builds a weekly timesheet from the clock plus a hand entry, edits it, submits, is returned by an independent shift
# leader, reopens, corrects and resubmits, and is approved. The sheet's audit history, CSV export, the midnight and
# daylight-saving boundaries, and the payroll lock are all checked.
class TimesheetLifecycleWalkthroughTest < ActionDispatch::IntegrationTest
  include WalkthroughHelper

  setup do
    synthetic_workspace('Walkthrough timesheets')
    @owner, @owner_worker = person('walk-owner@example.test', 'admin', 'Ada', 'Owner', rate_cents: 2000)
    @leader = User.create!(tenant: @tenant, email: 'walk-leader@example.test', name: 'Lee Leader', role: 'shift_leader', password: PASSWORD)
    @staff, @worker = person('walk-sam@example.test', 'employee', 'Sam', 'Staff', rate_cents: 1500)
    Current.reset
  end

  test 'timesheet lifecycle from clock punches to the payroll lock' do
    # 1. Clock punches from the staff app. A retried clock-in with the same request token returns the same shift.
    at('2026-10-01 09:00') do
      auth = app_login(@staff)
      post '/api/v1/employee/clock', params: { request_token: 'walkthrough-in-0001' }, headers: auth, as: :json
      assert_response :created
      @first_id = response.parsed_body.dig('data', 'id')
      post '/api/v1/employee/clock', params: { request_token: 'walkthrough-in-0001' }, headers: auth, as: :json
      assert_equal @first_id, response.parsed_body.dig('data', 'id')
    end
    at('2026-10-01 17:30') do
      patch "/api/v1/employee/clock/#{@first_id}", headers: app_login(@staff), as: :json
      assert_response :success
    end
    assert_equal 1, ClockShift.unscoped.where(tenant_id: @tenant.id, employee_id: @worker.id).count
    step 'Clock in 2026-10-01 09:00, retry same token, clock out 17:30 (staff app)', 'one shift, 8.50 h'

    # A shift across local midnight: 2026-10-02 22:00 to 2026-10-03 02:00.
    at('2026-10-02 22:00') do
      post '/api/v1/employee/clock', params: { request_token: 'walkthrough-in-0002' }, headers: app_login(@staff), as: :json
      @night_id = response.parsed_body.dig('data', 'id')
    end
    at('2026-10-03 02:00') { patch "/api/v1/employee/clock/#{@night_id}", headers: app_login(@staff), as: :json }
    step 'Clock in 2026-10-02 22:00, out 2026-10-03 02:00 (crosses local midnight)', 'one shift, 4.00 h'

    # 2. Corrections: the first shift really started at 08:45 (approved); a claim for the night shift is rejected.
    at('2026-10-03 10:00') do
      auth = app_login(@staff)
      post "/api/v1/employee/clock/#{@first_id}/corrections", headers: auth, as: :json,
        params: { clock_correction: { proposed_started_at: Time.zone.parse('2026-10-01 08:45').iso8601, proposed_ended_at: Time.zone.parse('2026-10-01 17:30').iso8601, reason: 'Opened the store at 8:45' } }
      assert_response :created
      @approve_id = response.parsed_body.dig('data', 'id')
      post "/api/v1/employee/clock/#{@night_id}/corrections", headers: auth, as: :json,
        params: { clock_correction: { proposed_started_at: Time.zone.parse('2026-10-02 21:00').iso8601, proposed_ended_at: Time.zone.parse('2026-10-03 02:00').iso8601, reason: 'Came in early' } }
      @reject_id = response.parsed_body.dig('data', 'id')
    end
    # Pending corrections block building the timesheet from the clock.
    at('2026-10-03 10:05') do
      auth = app_login(@staff)
      post '/api/v1/employee/timesheets', params: { timesheet: { period_start: '2026-10-01', period_end: '2026-10-07' } }, headers: auth, as: :json
      assert_response :created
      @sheet_id = response.parsed_body.dig('data', 'id')
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/import_shifts", headers: auth, as: :json
      assert_response :unprocessable_entity
    end
    step 'Staff create the week 2026-10-01..07 and import while two corrections are pending', 'refused (422): review corrections first'

    at('2026-10-03 11:00') do
      sign_in(@owner)
      post approve_correction_time_clock_path(@approve_id)
      assert_equal 'Correction approved and audited.', flash[:notice]
      post reject_correction_time_clock_path(@reject_id)
      assert_equal 'Correction rejected; shift times are unchanged.', flash[:notice]
    end
    tenant_scope do
      shift = ClockShift.find(@first_id)
      assert_equal Time.zone.parse('2026-10-01 08:45'), shift.started_at
      assert_equal Time.zone.parse('2026-10-02 22:00'), ClockShift.find(@night_id).started_at
      correction = ClockCorrection.find(@approve_id)
      assert_equal [Time.zone.parse('2026-10-01 09:00'), 'approved', @owner.id], [correction.original_started_at, correction.status, correction.reviewed_by_id]
    end
    step 'Owner approves the 08:45 start and rejects the 21:00 claim', 'shift 1 now 08:45-17:30 (8.75 h), original 09:00 kept; shift 2 unchanged'

    # 3. Build the sheet from the clock, add and edit a hand entry.
    at('2026-10-05 09:00') do
      auth = app_login(@staff)
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/import_shifts", headers: auth, as: :json
      assert_response :success
      entries = response.parsed_body.dig('data', 'entries').map { |e| [e['worked_on'], e['hours'].to_d] }
      assert_equal [['2026-10-01', 8.75.to_d], ['2026-10-02', 2.to_d], ['2026-10-03', 2.to_d]], entries
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/import_shifts", headers: auth, as: :json
      assert_equal 3, response.parsed_body.dig('data', 'entries').size
      post "/api/v1/employee/timesheets/#{@sheet_id}/entries", headers: auth, as: :json,
        params: { timesheet_entry: { worked_on: '2026-10-04', hours: '4', work_type: 'regular', notes: 'Off-site market stall' } }
      @hand_id = response.parsed_body.dig('data', 'entries').find { |e| e['clock_shift_id'].nil? }['id']
      patch "/api/v1/employee/timesheets/#{@sheet_id}/entries/#{@hand_id}", headers: auth, as: :json,
        params: { timesheet_entry: { worked_on: '2026-10-04', hours: '3.5', work_type: 'regular', notes: 'Off-site market stall' } }
      assert_equal '16.25', response.parsed_body.dig('data', 'total_hours')
    end
    step 'Import shifts (twice) and add a 4 h hand entry for 2026-10-04, edit it to 3.5 h',
      'entries 10-01 8.75, 10-02 2.00, 10-03 2.00 (midnight split), 10-04 3.50; re-import adds no duplicates; total 16.25 h'

    # 4. Submit, independent review returns it.
    at('2026-10-08 08:00') do
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/submit", headers: app_login(@staff), as: :json
      assert_equal 'submitted', response.parsed_body.dig('data', 'status')
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/approve", headers: app_login(@staff), as: :json
      assert_response :unprocessable_entity
    end
    step 'Staff submit; staff try to approve their own sheet through the app', 'submitted; self-approval refused (unsupported_action)'

    at('2026-10-08 10:00') do
      sign_in(@leader)
      get people_timesheet_path(@sheet_id)
      assert_response :success
      assert_select 'input[type="submit"][value="Approve"]'
      post reject_people_timesheet_path(@sheet_id), params: { review_note: 'The market stall ran 3 hours, not 3.5.' }
    end
    tenant_scope { assert_equal ['rejected', @leader.id], [People::Timesheet.find(@sheet_id).status, People::Timesheet.find(@sheet_id).reviewed_by] }
    step 'Shift leader opens the sheet and returns it with a note', 'rejected, reviewer = shift leader'

    # 5. Reopen, correct, resubmit; approve.
    at('2026-10-08 12:00') do
      auth = app_login(@staff)
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/reopen", headers: auth, as: :json
      assert_equal 'draft', response.parsed_body.dig('data', 'status')
      patch "/api/v1/employee/timesheets/#{@sheet_id}/entries/#{@hand_id}", headers: auth, as: :json,
        params: { timesheet_entry: { worked_on: '2026-10-04', hours: '3', work_type: 'regular', notes: 'Off-site market stall' } }
      assert_equal '15.75', response.parsed_body.dig('data', 'total_hours')
      post "/api/v1/employee/timesheets/#{@sheet_id}/actions/submit", headers: auth, as: :json
      assert_equal 'submitted', response.parsed_body.dig('data', 'status')
    end
    at('2026-10-08 14:00') do
      sign_in(@owner)
      post approve_people_timesheet_path(@sheet_id), params: { review_note: 'Checked against the clock.' }
    end
    tenant_scope do
      sheet = People::Timesheet.find(@sheet_id)
      assert_equal ['approved', @owner.id, 15.75.to_d], [sheet.status, sheet.reviewed_by, sheet.total_hours]
    end
    step 'Staff reopen, set 10-04 to 3 h, resubmit; owner approves', 'approved, 15.75 h (8.75 + 2 + 2 + 3)'

    # 6. Audit history.
    tenant_scope do
      sheet = People::Timesheet.find(@sheet_id)
      actions = sheet.events.order(:id).pluck(:action)
      assert_equal %w[created import_shifts import_shifts add_entry update_entry submit reject reopen update_entry submit approve], actions
      edit = sheet.events.where(action: 'update_entry').order(:id).last
      assert_equal ['3.5', '3.0'], [edit.details.dig('before', 'hours').to_s, edit.details.dig('after', 'hours').to_s]
      logged = ActivityLog.unscoped.where(tenant_id: @tenant.id).where('action LIKE ?', 'timesheet_%').pluck(:action)
      assert_includes logged, 'timesheet_reject'
      assert_includes logged, 'timesheet_approve'
      step 'Audit history on the sheet', "#{actions.size} events: #{actions.join(', ')}; the last edit stores before 3.5 / after 3.0; activity log has timesheet_*"
    end
    get "/api/v1/employee/timesheets/#{@sheet_id}", headers: app_login(@staff), as: :json
    assert_equal 11, response.parsed_body.dig('data', 'history').size
    step 'Staff app shows the same history to the staff member', '11 history rows'

    # 7. Export.
    sign_in(@owner)
    get people_timesheet_path(@sheet_id, format: :csv)
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal [%w[2026-10-01 8.75], %w[2026-10-02 2.0], %w[2026-10-03 2.0], %w[2026-10-04 3.0]], rows.map { |r| [r['Date'], r['Hours']] }
    assert(rows.all? { |r| r['Status'] == 'approved' && r['Employee'] == 'Sam Staff' })
    get people_timesheets_path(format: :csv, status: 'approved')
    assert_equal 4, CSV.parse(response.body, headers: true).count
    step 'CSV export of the sheet and of the approved list', '4 rows: 8.75, 2.0, 2.0, 3.0, status approved'

    # 8. Daylight-saving boundary: clocked 2026-10-31 22:00 EDT to 2026-11-01 03:00 EST is 6 real hours (5 on the wall).
    at('2026-10-31 22:00') do
      post '/api/v1/employee/clock', params: { request_token: 'walkthrough-dst-0003' }, headers: app_login(@staff), as: :json
      @dst_id = response.parsed_body.dig('data', 'id')
    end
    at('2026-11-01 03:00') { patch "/api/v1/employee/clock/#{@dst_id}", headers: app_login(@staff), as: :json }
    at('2026-11-02 09:00') do
      auth = app_login(@staff)
      post '/api/v1/employee/timesheets', params: { timesheet: { period_start: '2026-10-29', period_end: '2026-11-04' } }, headers: auth, as: :json
      dst_sheet = response.parsed_body.dig('data', 'id')
      post "/api/v1/employee/timesheets/#{dst_sheet}/actions/import_shifts", headers: auth, as: :json
      entries = response.parsed_body.dig('data', 'entries').map { |e| [e['worked_on'], e['hours'].to_d] }
      assert_equal [['2026-10-31', 2.to_d], ['2026-11-01', 4.to_d]], entries
      assert_equal '6.0', response.parsed_body.dig('data', 'total_hours')
    end
    step 'DST: clock 2026-10-31 22:00 EDT to 2026-11-01 03:00 EST, import', '10-31 2.00 h + 11-01 4.00 h = 6.00 h elapsed (wall clock shows 5)'

    # 9. Pay run include and the payroll lock.
    at('2026-10-09 09:00') do
      sign_in(@owner)
      post people_pay_runs_path, params: { pay_run: { name: 'Walkthrough week 1', period_start: '2026-10-01', period_end: '2026-10-07' } }
      assert_match(/Pay run created with 1 payslips/, flash[:notice])
      tenant_scope do
        slip = People::PayRun.find_by!(name: 'Walkthrough week 1').payslips.sole
        assert_equal [@worker.id, 15.75.to_d, 23_625], [slip.employee_id, slip.hours.to_d, slip.gross_cents]
      end
      post reopen_people_timesheet_path(@sheet_id)
      assert_match(/included in payroll/, flash[:alert])
    end
    tenant_scope { assert_equal 'approved', People::Timesheet.find(@sheet_id).status }
    step 'Owner creates a pay run for 2026-10-01..07; then tries to reopen the paid sheet',
      'one payslip: Sam 15.75 h x $15.00 = $236.25; reopen refused (included in payroll)'
  end
end
