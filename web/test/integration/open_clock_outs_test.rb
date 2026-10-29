# frozen_string_literal: true

require 'test_helper'

# Forgotten clock-outs: flagged after the workspace's limit, shown on the hours pages with a
# Fix clock-out that goes through a reviewed ClockCorrection, told to managers once, and
# never counted until fixed.
class OpenClockOutsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    Current.user = @admin
    @staff = User.create!(tenant: @tenant, email: 'forgot-clockout@example.invalid', password: 'password123', role: 'employee')
    @worker = People::Employee.create!(user: @staff, first_name: 'Justin', last_name: 'Forgot')
    @second_admin = User.create!(tenant: @tenant, email: 'second-reviewer@example.invalid', password: 'password123', role: 'admin')
  end
  teardown { Current.reset }

  def open_shift(started_at)
    ClockShift.create!(user: @staff, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name,
      employment_type: @worker.employment_type, started_at: started_at, request_token: SecureRandom.uuid)
  end

  def sign_in(user, password)
    post login_path, params: { email: user.email, password: password }
  end

  test 'the limit is a pay-rules setting and only shifts open past it are flagged and left uncounted' do
    travel_to Time.zone.parse('2026-10-29 12:00') do
      fresh = open_shift(Time.zone.parse('2026-10-29 06:00'))
      assert_not fresh.stale_open?
      fresh.update_columns(started_at: Time.zone.parse('2026-10-28 18:00'))
      assert fresh.reload.stale_open?
      assert_equal [fresh], OpenClockOuts.new.shifts.to_a
      assert_equal fresh.started_at, fresh.counted_end

      PayRules.save!({ open_shift_limit_hours: 20 }, actor: @admin)
      assert_not fresh.stale_open?
      assert_equal Time.current, fresh.counted_end
      assert_raises(PayRules::Invalid) { PayRules.save!({ open_shift_limit_hours: 30 }, actor: @admin) }
      assert_raises(PayRules::Invalid) { PayRules.save!({ open_shift_limit_hours: 2 }, actor: @admin) }
    end
  end

  test 'hours pages warn, the week calendar stops counting, and the employee page links to Fix clock-out' do
    travel_to Time.zone.parse('2026-10-29 12:00') do
      shift = open_shift(Time.zone.parse('2026-10-17 11:29'))
      sign_in(@admin, 'password')
      [people_timesheets_path, people_time_keeping_path, people_punch_history_path(from: '2026-10-01', to: '2026-10-29'),
       people_employee_path(@worker), time_clock_path].each do |path|
        get path
        assert_response :success, path
        assert_select "[data-open-clock-out='rupert-#{shift.id}']", { text: /Clocked in 12 days ago and never clocked out/ }, path
        assert_select "[data-open-clock-out='rupert-#{shift.id}'] a[href=?]", fix_clock_out_time_clock_path(shift), { text: 'Fix clock-out' }, path
      end

      calendar = TimesheetCalendar.new(Date.new(2026, 10, 26), user: @admin)
      assert_empty calendar.clocked_in
      assert_equal 0.0, calendar.hours_by_employee.fetch(@worker.id, {}).values.sum
      summary = EmployeeWorkSummary.new(employee: @worker, from: Date.new(2026, 10, 1), to: Date.new(2026, 10, 29))
      assert_equal 0, summary.clock_hours
    end
  end

  test 'Fix clock-out files a pre-filled correction for review; the shift changes only when another reviewer approves' do
    travel_to Time.zone.parse('2026-10-29 12:00') do
      shift = open_shift(Time.zone.parse('2026-10-17 11:29'))
      People::ScheduledShift.create!(employee: @worker, starts_at: Time.zone.parse('2026-10-17 11:00'), ends_at: Time.zone.parse('2026-10-17 18:00'))
      sign_in(@admin, 'password')
      get fix_clock_out_time_clock_path(shift)
      assert_response :success
      assert_select 'h1', 'Fix clock-out'
      assert_select 'input[name=?][value=?]', 'clock_correction[proposed_ended_at]', '2026-10-17T18:00:00'
      assert_select 'textarea[name=?]', 'clock_correction[reason]', text: /Forgot to clock out/

      post request_correction_time_clock_path(shift), params: { clock_correction: {
        proposed_started_at: '2026-10-17T11:29:00', proposed_ended_at: '2026-10-17T18:00:00', reason: 'Forgot to clock out; left at six' } }
      assert_redirected_to time_clock_path
      correction = shift.corrections.sole
      assert_equal [@admin.id, 'pending'], [correction.requested_by_id, correction.status]
      assert_nil shift.reload.ended_at

      error = assert_raises(TimeClockService::Error) { TimeClockService.review(correction: correction, reviewer: @admin, approve: true) }
      assert_match 'Another reviewer', error.message
      get people_timesheets_path
      assert_select "[data-open-clock-out='rupert-#{shift.id}']", text: /Correction waiting for review/

      TimeClockService.review(correction: correction, reviewer: @second_admin, approve: true)
      assert_equal Time.zone.parse('2026-10-17 18:00'), shift.reload.ended_at
      assert_equal [Time.zone.parse('2026-10-17 11:29'), nil], [correction.reload.original_started_at, correction.original_ended_at]
      assert_empty OpenClockOuts.new.shifts
    end
  end

  test 'staff can fix their own forgotten clock-out but not open anyone else\'s' do
    travel_to Time.zone.parse('2026-10-29 12:00') do
      mine = open_shift(Time.zone.parse('2026-10-27 08:00'))
      other_user = User.create!(tenant: @tenant, email: 'other-forgot@example.invalid', password: 'password123', role: 'employee')
      other = People::Employee.create!(user: other_user, first_name: 'Other', last_name: 'Person')
      theirs = ClockShift.create!(user: other_user, employee: other, employee_key: other.id.to_s, employee_name: other.name,
        employment_type: other.employment_type, started_at: Time.zone.parse('2026-10-27 08:00'), request_token: SecureRandom.uuid)
      sign_in(@staff, 'password123')
      get time_clock_path
      assert_select "[data-open-clock-out='rupert-#{mine.id}'] a", 'Fix clock-out'
      assert_select "[data-open-clock-out='rupert-#{theirs.id}']", 0
      get fix_clock_out_time_clock_path(mine)
      assert_response :success
      get fix_clock_out_time_clock_path(theirs)
      assert_response :not_found
      post request_correction_time_clock_path(theirs), params: { clock_correction: {
        proposed_started_at: '2026-10-27T08:00:00', proposed_ended_at: '2026-10-27T12:00:00', reason: 'not mine' } }
      assert_response :not_found
      assert_empty theirs.corrections
    end
  end

  test 'managers are told once per open shift; the worker is not told about their own; open Square cards count too' do
    travel_to Time.zone.parse('2026-10-29 12:00') do
      shift = open_shift(Time.zone.parse('2026-10-17 11:29'))
      card = SquareTimecard.create!(external_id: 'open-square-card', import_status: 'open', employee: @worker, team_member_id: 'tm',
        started_at: Time.zone.parse('2026-10-20 09:00'), last_seen_at: Time.current)
      own = ->(user) { Notification.where(user: user, kind: 'open_clock_out').pluck(:dedupe_key).sort }
      OpenClockOutAlertJob.perform_now
      assert_no_difference -> { Notification.count } do
        OpenClockOutAlertJob.perform_now
      end
      expected = ["open_clock_out:rupert:#{shift.id}", "open_clock_out:square:#{card.id}"]
      assert_equal expected, own.call(@admin)
      assert_equal expected, own.call(@second_admin)
      note = Notification.find_by!(user: @admin, dedupe_key: "open_clock_out:rupert:#{shift.id}")
      assert_equal 'Justin Forgot never clocked out', note.title
      assert_match(/Clocked in 12 days ago/, note.body)
      assert_equal fix_clock_out_time_clock_path(shift), note.url

      # A manager whose own clock-in is forgotten is not told about it.
      manager_worker = People::Employee.create!(user: @second_admin, first_name: 'Second', last_name: 'Manager')
      later = ClockShift.create!(user: @second_admin, employee: manager_worker, employee_key: manager_worker.id.to_s, employee_name: manager_worker.name,
        employment_type: manager_worker.employment_type, started_at: Time.zone.parse('2026-10-25 09:00'), request_token: SecureRandom.uuid)
      OpenClockOutAlertJob.perform_now
      assert Notification.exists?(user: @admin, dedupe_key: "open_clock_out:rupert:#{later.id}")
      assert_not Notification.exists?(user: @second_admin, dedupe_key: "open_clock_out:rupert:#{later.id}")
      assert_not Notification.exists?(user: @staff)
    end
  end
end
