# frozen_string_literal: true

require 'test_helper'

# Production-readiness edges for Rupert's own clock and timesheets: the Nov 1 2026 daylight
# saving change, shifts split across days and pay weeks, punches left open, self-review of
# clock corrections, the pay rate a pay run uses and pay-period-aligned timesheets.
class TimesheetProductionReadinessTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    Current.user = @admin
    @user = User.create!(tenant: Current.tenant, email: 'readiness-worker@example.com', role: 'cashier', password: 'password')
    @worker = People::Employee.create!(user: @user, first_name: 'Ready', last_name: 'Worker', employment_type: 'part_time')
    People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2000, effective_on: '2026-01-01')
  end

  teardown { Current.reset }

  def shift(from, to, user: @user, worker: @worker)
    ClockShift.create!(user: user, employee: worker, employee_key: worker.id.to_s, employee_name: worker.name,
      employment_type: worker.employment_type, started_at: Time.zone.parse(from), ended_at: to && Time.zone.parse(to),
      request_token: SecureRandom.uuid)
  end

  def approved_sheet(first, last)
    workflow = TimesheetWorkflow.new(user: @admin)
    sheet = workflow.create(employee_id: @worker.id, period_start: first, period_end: last)
    workflow.change(sheet, :import_shifts)
    workflow.change(sheet, :submit)
    workflow.change(sheet, :approve)
    sheet.reload
  end

  test 'the Nov 1 2026 DST week: an overnight shift is split at local midnight and counts its real 9 hours' do
    travel_to Time.zone.parse('2026-11-10 12:00') do
      # 10 pm EDT Oct 31 to 6 am EST Nov 1: the clock reads 8 hours, 9 really passed (1-2 am repeats).
      shift('2026-10-31 22:00 -04:00', '2026-11-01 06:00 -05:00')
      assert_equal [Date.new(2026, 10, 29), Date.new(2026, 11, 4)], PayRules.current.period_range(Date.new(2026, 11, 1))

      sheet = approved_sheet(Date.new(2026, 10, 29), Date.new(2026, 11, 4))
      assert_equal({ Date.new(2026, 10, 31) => 2.0.to_d, Date.new(2026, 11, 1) => 7.0.to_d },
        sheet.entries.ordered.to_h { |entry| [entry.worked_on, entry.hours] })

      pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 11, 1))
      assert_in_delta 9.0, pay.hours, 0.0001
      assert_equal 18_000, pay.base_cents

      run = People::PayRun.create!(name: 'DST week', period_start: '2026-10-29', period_end: '2026-11-04')
      People::PayrollCalculator.generate!(run)
      assert_equal 9, run.payslips.sole.hours
      assert_equal 18_000, run.payslips.sole.gross_cents
    end
  end

  test 'a shift crossing the pay week boundary pays each part in its own pay run' do
    travel_to Time.zone.parse('2026-11-10 12:00') do
      # Wednesday 8 pm to Thursday 2 am: the Thursday-Wednesday pay week ends at Wednesday midnight.
      shift('2026-11-04 20:00', '2026-11-05 02:00')
      approved_sheet(Date.new(2026, 10, 29), Date.new(2026, 11, 4))
      approved_sheet(Date.new(2026, 11, 5), Date.new(2026, 11, 8))
      first = People::PayRun.create!(name: 'Week 1', period_start: '2026-10-29', period_end: '2026-11-04')
      second = People::PayRun.create!(name: 'Week 2', period_start: '2026-11-05', period_end: '2026-11-11')
      People::PayrollCalculator.generate!(first)
      People::PayrollCalculator.generate!(second)
      assert_equal [4, 2], [first.payslips.sole.hours, second.payslips.sole.hours]
    end
  end

  test 'a punch left open past the limit counts nothing in pay, commission and tip estimates until fixed' do
    travel_to Time.zone.parse('2026-10-25 12:00') do
      open = shift('2026-10-17 09:00', nil)
      assert open.stale_open?
      assert_equal open.started_at, open.counted_end
      pay = EmployeePayWeek.new(employee: @worker, week_of: Date.new(2026, 10, 17))
      assert_in_delta 0.0, pay.hours, 0.0001
      assert(pay.notes.any? { |note| note.include?('open more than 16 hours') && note.include?('counts no hours') })

      # A sale two days later is not credited to the forgotten punch.
      order = Core::Order.new(source: 'shopify', source_order_id: SecureRandom.uuid, occurred_at: Time.zone.parse('2026-10-19 10:00'),
        gross_cents: 11_000, tax_cents: 1000, tip_cents: 500, currency: 'USD')
      order.aasm.current_state = :paid
      order.save!
      order.order_lines.create!(name: 'Merchandise', unit_cents: 10_000, quantity: 1, line_cents: 10_000)
      order.payments.create!(method: 'card', amount_cents: 11_000, status: 'completed', paid_at: order.occurred_at)
      preview = CommissionPreview.new(start_date: '2026-10-17', end_date: '2026-10-25', source: 'shopify', currency: 'USD')
      assert_equal 1, preview.stale_open_shifts
      assert_equal 0, preview.rows.sole[:commission_cents]
      assert_equal 500, preview.unassigned_tip_cents
    end
  end

  test 'a punch open more than 24 hours cannot simply be clocked out; it needs a correction' do
    travel_to Time.zone.parse('2026-10-25 12:00') do
      open = shift('2026-10-17 09:00', nil)
      error = assert_raises(TimeClockService::Error) { TimeClockService.clock_out(user: @user, shift_id: open.id) }
      assert_match 'Request a correction', error.message
      assert_nil open.reload.ended_at
      assert_not open.update(ended_at: Time.zone.parse('2026-10-19 09:00'))

      correction = TimeClockService.request_correction(user: @user, shift_id: open.id, attributes: {
        proposed_started_at: Time.zone.parse('2026-10-17 09:00'), proposed_ended_at: Time.zone.parse('2026-10-17 17:00'), reason: 'Forgot to clock out'
      })
      TimeClockService.review(correction: correction, reviewer: @admin, approve: true)
      assert_equal 8, open.reload.hours
    end
  end

  test 'a reviewer cannot approve or reject a correction to their own shift' do
    travel_to Time.zone.parse('2026-10-25 12:00') do
      own_worker = People::Employee.create!(user: @admin, first_name: 'Admin', last_name: 'Worker', employment_type: 'full_time')
      own = shift('2026-10-24 09:00', '2026-10-24 12:00', user: @admin, worker: own_worker)
      correction = TimeClockService.request_correction(user: @admin, shift_id: own.id, attributes: {
        proposed_started_at: Time.zone.parse('2026-10-24 08:00'), proposed_ended_at: Time.zone.parse('2026-10-24 12:00'), reason: 'Early start'
      })
      [true, false].each do |approve|
        assert_raises(TimeClockService::Error) { TimeClockService.review(correction: correction, reviewer: @admin, approve: approve) }
      end
      assert_equal 'pending', correction.reload.status
      assert_equal Time.zone.parse('2026-10-24 09:00'), own.reload.started_at
    end
  end

  test "a pay run uses the rate for its own period, and lists approved hours with no rate instead of dropping them" do
    travel_to Time.zone.parse('2026-11-10 12:00') do
      @worker.pay_rates.sole.update!(ended_on: '2026-11-04')
      People::PayRate.create!(employee: @worker, pay_type: 'hourly', hourly_rate_cents: 2500, effective_on: '2026-11-05')
      shift('2026-11-02 09:00', '2026-11-02 13:00')
      approved_sheet(Date.new(2026, 10, 29), Date.new(2026, 11, 4))
      run = People::PayRun.create!(name: 'Before the raise', period_start: '2026-10-29', period_end: '2026-11-04')
      People::PayrollCalculator.generate!(run)
      assert_equal 8000, run.payslips.sole.gross_cents
      assert_empty run.employees_without_rate

      @worker.pay_rates.destroy_all
      People::PayrollCalculator.generate!(run)
      assert_empty run.payslips.reload
      assert_equal [@worker], run.employees_without_rate
    end
  end

  test 'a new timesheet follows the pay period and does not overlap an existing sheet' do
    travel_to Time.zone.parse('2026-11-02 12:00') do
      assert_equal [Date.new(2026, 10, 29), Date.new(2026, 11, 4)], People::Timesheet.default_period_for(@worker)
      # An older Monday-Sunday sheet already covers Oct 26 - Nov 1: the new sheet starts after it.
      People::Timesheet.create!(employee: @worker, period_start: '2026-10-26', period_end: '2026-11-01')
      assert_equal [Date.new(2026, 11, 2), Date.new(2026, 11, 4)], People::Timesheet.default_period_for(@worker)

      PayRules.save!({ pay_period: 'biweekly', week_start_day: 'thursday', anchor_date: '2026-10-29' }, actor: @admin)
      assert_equal [Date.new(2026, 11, 2), Date.new(2026, 11, 11)], People::Timesheet.default_period_for(@worker)
    end
  end
end
