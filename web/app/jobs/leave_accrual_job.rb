# frozen_string_literal: true

# Daily leave accrual (docs/time-and-pay/DECISIONS.md), per active worker, per store rules (TimeRules):
#
# - Sick time accrues on paid hours worked since the last run (`sick_accrual_hours_per_hour_worked`),
#   up to the cap for the year; the watermark `employees.sick_accrued_through` stops double counting.
# - Vacation (and the sick annual grant, when accrual is off) is granted once per calendar year on
#   January 1 or the first run after it, from `vacation_annual_hours` / `sick_annual_hours`.
# - On the first run of a new year, last year's unused hours carry over up to `carryover_max_hours`.
#
# Every change is a People::LeaveAccrual line; LeaveBalance#accrued_hours is the running sum.
class LeaveAccrualJob < ApplicationJob
  queue_as :default

  def perform(today: Date.current)
    Tenant.where(status: 'active').find_each do |tenant|
      Current.set(tenant: tenant) { BusinessClock.use(tenant: tenant) { LeaveAccrual.run!(today: today) } }
    rescue StandardError => e
      logger.error("#{self.class}: leave accrual failed for tenant #{tenant.id}: #{e.class}")
    end
  end

  # The accrual itself, runnable in a test or console for one tenant.
  module LeaveAccrual
    module_function

    def run!(today: Date.current)
      People::Employee.active.find_each do |employee|
        rules = TimeRules.for(employee.location_ids.first)
        annual_grant!(employee, rules, today)
        accrue_worked!(employee, rules, today)
      end
    end

    def annual_grant!(employee, rules, today)
      year = today.year
      return if employee.vacation_granted_for_year.to_i >= year

      People::Employee.transaction do
        carry_over!(employee, rules, year) if employee.vacation_granted_for_year.present?
        grant!(employee, 'vacation', rules.vacation_annual_hours, year) if rules.vacation_annual_hours.positive?
        grant!(employee, 'sick', rules.sick_annual_hours, year) if !rules.sick_accrues? && rules.sick_annual_hours.positive?
        employee.update_columns(vacation_granted_for_year: year, updated_at: Time.current)
      end
    end

    def grant!(employee, leave_type, hours, year)
      balance = employee.leave_balances.find_or_initialize_by(leave_type: leave_type, year: year)
      balance.accrued_hours = (balance.accrued_hours || 0) + hours
      balance.save!
      employee.leave_accruals.create!(leave_type: leave_type, hours: hours, reason: 'annual_grant', year: year)
    end

    def carry_over!(employee, rules, year)
      %w[vacation sick].each do |leave_type|
        last = employee.leave_balances.find_by(leave_type: leave_type, year: year - 1)
        next if last.nil? || last.remaining_hours <= 0

        carried = rules.carryover_max_hours ? [last.remaining_hours, rules.carryover_max_hours].min : last.remaining_hours
        lost = last.remaining_hours - carried
        balance = employee.leave_balances.find_or_initialize_by(leave_type: leave_type, year: year)
        balance.accrued_hours = (balance.accrued_hours || 0) + carried
        balance.save!
        employee.leave_accruals.create!(leave_type: leave_type, hours: carried, reason: 'carryover', year: year) if carried.positive?
        employee.leave_accruals.create!(leave_type: leave_type, hours: -lost, reason: 'carryover_cap', year: year - 1) if lost.positive?
      end
    end

    def accrue_worked!(employee, rules, today)
      return unless rules.sick_accrues?

      since = employee.sick_accrued_through || employee.hire_date&.in_time_zone || 1.year.ago
      cutoff = today.in_time_zone.beginning_of_day
      shifts = ClockShift.where(employee_id: employee.id).where.not(ended_at: nil).where('ended_at > ? AND ended_at <= ?', since, cutoff).includes(:breaks).to_a
      hours = shifts.sum { |shift| shift.paid_hours.to_d }
      People::Employee.transaction do
        if hours.positive?
          balance = employee.leave_balances.find_or_initialize_by(leave_type: 'sick', year: today.year)
          earned = (hours * rules.sick_accrual_hours_per_hour_worked).round(2)
          room = rules.sick_accrual_cap_hours ? [rules.sick_accrual_cap_hours - (balance.accrued_hours || 0), 0].max : earned
          earned = [earned, room].min
          if earned.positive?
            balance.accrued_hours = (balance.accrued_hours || 0) + earned
            balance.save!
            employee.leave_accruals.create!(leave_type: 'sick', hours: earned, reason: 'worked', year: today.year,
              period_start: since.to_date, period_end: cutoff.to_date)
          end
        end
        employee.update_columns(sick_accrued_through: cutoff, updated_at: Time.current)
      end
    end
  end
end
