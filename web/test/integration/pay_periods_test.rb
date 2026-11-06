# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

# Pay periods: figures per employee, lock with blocking warnings, provider-agnostic CSV with a recorded
# digest, reopen with a reason, and the lock refusing late punches, hours and time off.
class PayPeriodsTest < ActionDispatch::IntegrationTest
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  # Period Thu 2026-10-29 .. Wed 2026-11-04 (PayRules default weekly Thursday).
  def seed_period!
    sheet = tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-30' => 8, '2026-10-31' => 4 })
    Current.user = @manager
    TimesheetWorkflow.new(user: @manager).change(sheet, :approve, review_note: nil)
    TipAllocation.create!(employee: @worker, source_kind: 'manual', tip_method: 'pool', amount_cents: 1250, occurred_at: Time.zone.parse('2026-10-30 13:00'), business_date: Date.new(2026, 10, 30))
    TipAllocation.create!(employee: @worker, source_kind: 'declared', tip_method: 'cash', amount_cents: 500, occurred_at: Time.zone.parse('2026-10-31 13:00'), business_date: Date.new(2026, 10, 31))
    leave = @worker.leave_requests.create!(leave_type: 'sick', starts_on: '2026-11-02', ends_on: '2026-11-02', hours: 8)
    LeaveRequestWorkflow.change(leave, :approve, notify: false)
    sheet
  end

  test 'shows the period figures, locks, exports a csv with a digest and reopens with a reason' do
    travel_to Time.zone.parse('2026-11-06 10:00') do
      seed_period!
      tp_sign_in(@admin)
      get people_pay_periods_path
      assert_response :success
      assert_select '[data-pay-period="2026-10-29"]'
      period = PayPeriod.find_by!(starts_on: '2026-10-29')
      get people_pay_period_path(period)
      assert_response :success
      # 12 h regular x $15 = $180; sick 8 h x $15 = $120; tips 12.50 + 5.00 → gross $317.50
      assert_select "[data-pay-row='#{@worker.id}']", text: /Sam Staff.*12\.00.*8\.00.*\$15\.00\/h.*\$12\.50.*\$5\.00.*\$317\.50/m
      assert_select 'button', text: 'Lock period'
      post lock_people_pay_period_path(period)
      assert period.reload.locked?
      assert_equal @admin.id, period.locked_by_id
      get people_pay_period_path(period, format: :csv)
      assert_response :success
      rows = CSV.parse(response.body, headers: true)
      assert_equal PayrollExport::COLUMNS, rows.headers
      row = rows.find { |r| r['name'] == 'Sam Staff' }
      assert_equal %w[12.00 0.00 8.00 15.00 12.50 5.00 317.50], [row['regular_hours'], row['overtime_hours'], row['sick_hours'], row['hourly_rate'], row['card_tips'], row['cash_tips'], row['estimated_gross']]
      assert_equal 'exported', period.reload.status
      assert_equal Digest::SHA256.hexdigest(response.body), period.export_sha256
      post reopen_people_pay_period_path(period)
      assert_match(/Say why/, flash[:alert])
      post reopen_people_pay_period_path(period), params: { reason: 'Provider asked for a resend' }
      assert period.reload.open?
      assert_match(/Provider asked for a resend/, period.note)
    end
  end

  test 'blocking warnings stop a lock unless locked anyway with a reason' do
    travel_to Time.zone.parse('2026-11-06 10:00') do
      tp_submitted_sheet!(@worker, '2026-10-29', { '2026-10-30' => 8 }) # submitted, not approved
      tp_sign_in(@admin)
      period = PayPeriod.for_date(Date.new(2026, 10, 29))
      get people_pay_period_path(period)
      assert_select '[data-period-warnings]', text: /1 thing to fix before locking.*timesheet Oct 29 – Nov 4, 2026 is submitted, not approved/m
      post lock_people_pay_period_path(period)
      assert period.reload.open?
      assert_match(/to fix first/, flash[:alert])
      post lock_people_pay_period_path(period), params: { lock_anyway: '1', reason: 'Paying on estimates this once' }
      assert period.reload.locked?
      assert_match(/Paying on estimates/, period.note)
    end
  end

  test 'a locked period refuses punches, timesheet hours, corrections and time off inside it, and takes adjustments on the next one' do
    travel_to Time.zone.parse('2026-11-06 10:00') do
      shift = tp_shift!(@worker, '2026-10-30 09:00', '2026-10-30 17:00')
      Current.user = @admin
      period = PayPeriod.for_date(Date.new(2026, 10, 29))
      period.lock!(by: @admin)
      late = ClockShift.new(user: @worker_user, employee: @worker, employee_key: @worker.id.to_s, employee_name: @worker.name, employment_type: 'part_time',
        started_at: Time.zone.parse('2026-10-31 09:00'), ended_at: Time.zone.parse('2026-10-31 12:00'), request_token: SecureRandom.uuid)
      assert_not late.valid?
      assert_match(/locked pay period/, late.errors.full_messages.to_sentence)
      assert_not shift.breaks.build(kind: 'meal', started_at: shift.started_at + 4.hours, ended_at: shift.started_at + 4.5.hours).valid?
      draft = @worker.timesheets.create!(period_start: '2026-10-29', period_end: '2026-11-04')
      entry = draft.entries.build(worked_on: '2026-10-30', hours: 8, work_type: 'regular')
      assert_not entry.valid?
      correction = shift.corrections.create!(requested_by_id: @worker_user.id, original_started_at: shift.started_at, original_ended_at: shift.ended_at,
        proposed_started_at: shift.started_at, proposed_ended_at: shift.ended_at + 1.hour, reason: 'Stayed late')
      error = assert_raises(ActiveRecord::RecordInvalid) { TimeClockService.review(correction: correction, reviewer: @manager, approve: true) }
      assert_match(/locked pay period/, error.message)
      assert_equal 'pending', correction.reload.status
      leave = @worker.leave_requests.create!(leave_type: 'vacation', starts_on: '2026-11-03', ends_on: '2026-11-03', hours: 8)
      assert_raises(ActiveRecord::RecordInvalid) { LeaveRequestWorkflow.change(leave, :approve, notify: false) }
      assert leave.reload.requested?
      # Open periods still accept everything.
      assert tp_shift!(@worker, '2026-11-05 09:00', '2026-11-05 12:00').persisted?
      # The difference goes on the next open period as an adjustment.
      next_period = PayPeriod.for_date(Date.new(2026, 11, 5))
      tp_sign_in(@admin)
      post adjustments_people_pay_period_path(next_period), params: { adjustment: { employee_id: @worker.id, kind: 'hours', hours: '1', note: 'Stayed late Oct 30, period already locked' } }
      assert_redirected_to people_pay_period_path(next_period, anchor: 'adjustments')
      assert_equal 1, next_period.adjustments.count
      get people_pay_period_path(next_period)
      assert_select '#adjustments', text: /Sam Staff · Hours \+1 h.*Stayed late Oct 30/m
      assert_select "[data-pay-row='#{@worker.id}']", text: /Adjustment: Hours \+1 h/
    end
  end

  test 'managers without payroll permission are refused and administrators get in' do
    tp_sign_in(@manager)
    get people_pay_periods_path
    assert_response :redirect, 'managers have no payroll permission'
    tp_sign_in(@admin)
    get people_pay_periods_path
    assert_response :success
  end
end
