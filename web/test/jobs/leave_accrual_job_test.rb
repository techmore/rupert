# frozen_string_literal: true

require 'test_helper'
require_relative '../support/time_and_pay_helper'

class LeaveAccrualJobTest < ActiveSupport::TestCase
  include TimeAndPayHelper

  setup { time_and_pay_workspace }
  teardown { Current.reset }

  test 'grants the annual allowance once, accrues sick time on paid hours worked up to the cap, and carries over at year end' do
    TimeRules.save!({ 'sick_accrual_hours_per_hour_worked' => '0.0333', 'sick_accrual_cap_hours' => '2', 'vacation_annual_hours' => '80', 'carryover_max_hours' => '10' }, actor: @admin)
    travel_to Time.zone.parse('2026-11-02 05:00') do
      shift = tp_shift!(@worker, '2026-10-30 09:00', '2026-10-30 17:00')
      shift.breaks.create!(kind: 'meal', paid: false, started_at: shift.started_at + 4.hours, ended_at: shift.started_at + 4.5.hours)
      LeaveAccrualJob.perform_now
      @worker.reload
      vacation = @worker.leave_balances.find_by!(leave_type: 'vacation', year: 2026)
      sick = @worker.leave_balances.find_by!(leave_type: 'sick', year: 2026)
      assert_equal 80, vacation.accrued_hours
      assert_in_delta 0.25, sick.accrued_hours, 0.01, '7.5 paid hours x 0.0333'
      assert_equal 2026, @worker.vacation_granted_for_year
      LeaveAccrualJob.perform_now
      assert_equal 80, vacation.reload.accrued_hours, 'the grant happens once a year'
      assert_in_delta 0.25, sick.reload.accrued_hours, 0.01, 'hours already counted are not counted twice'
      assert_equal %w[annual_grant worked], @worker.leave_accruals.chronological.pluck(:reason)
    end
    travel_to Time.zone.parse('2026-11-10 05:00') do
      # 100 paid hours would earn 3.33 h; the cap of 2 leaves room for 1.75.
      10.times { |i| tp_shift!(@worker, "2026-11-0#{(i % 7) + 1} 09:00", "2026-11-0#{(i % 7) + 1} 19:00") rescue nil }
      LeaveAccrualJob.perform_now
      assert_in_delta 2.0, @worker.leave_balances.find_by!(leave_type: 'sick', year: 2026).accrued_hours, 0.01
    end
    travel_to Time.zone.parse('2027-01-01 05:00') do
      vacation = @worker.leave_balances.find_by!(leave_type: 'vacation', year: 2026)
      vacation.update!(used_hours: 60) # 20 left; cap 10 carries
      LeaveAccrualJob.perform_now
      new_year = @worker.leave_balances.find_by!(leave_type: 'vacation', year: 2027)
      assert_equal 90, new_year.accrued_hours, '80 granted + 10 carried'
      assert_equal(-10, @worker.leave_accruals.find_by(reason: 'carryover_cap').hours)
    end
  end

  test 'without accrual rules only the annual grants are written' do
    travel_to Time.zone.parse('2026-06-01 05:00') do
      LeaveAccrualJob.perform_now
      assert_equal 80, @worker.leave_balances.find_by!(leave_type: 'vacation', year: 2026).accrued_hours
      assert_equal 40, @worker.leave_balances.find_by!(leave_type: 'sick', year: 2026).accrued_hours
      assert_nil @worker.reload.sick_accrued_through
    end
  end
end
