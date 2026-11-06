# frozen_string_literal: true

# Shared setup for the manager-side time & pay tests: a fresh workspace with a manager, a worker
# with a login and an hourly rate, and helpers to punch and submit hours.
module TimeAndPayHelper
  PASSWORD = 'password123'

  def time_and_pay_workspace(name = 'Time & pay workspace')
    @tenant = Tenant.create!(name: name, subdomain: "tp#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    @manager = User.create!(tenant: @tenant, email: "manager-#{SecureRandom.hex(3)}@example.com", name: 'Mia Manager', role: 'manager', password: PASSWORD)
    @admin = User.create!(tenant: @tenant, email: "admin-#{SecureRandom.hex(3)}@example.com", name: 'Ada Admin', role: 'admin', password: PASSWORD)
    @worker_user, @worker = tp_person('Sam', 'Staff', rate_cents: 1500)
    Current.user = @admin
    @tenant
  end

  def tp_person(first, last, rate_cents: 1500, role: 'employee', location_ids: [])
    user = User.create!(tenant: @tenant, email: "#{first.downcase}-#{SecureRandom.hex(3)}@example.com", name: "#{first} #{last}", role: role, password: PASSWORD)
    employee = People::Employee.create!(first_name: first, last_name: last, user: user, employment_type: 'part_time', hire_date: Date.new(2025, 1, 6))
    employee.update!(location_ids: location_ids) if location_ids.any?
    People::PayRate.create!(employee: employee, pay_type: 'hourly', hourly_rate_cents: rate_cents, pay_frequency: 'weekly', effective_on: '2025-01-01') if rate_cents
    [user, employee]
  end

  def tp_shift!(employee, from, to = nil, source: 'web', location_id: nil)
    user = employee.user
    ClockShift.create!(user: user, employee: employee, employee_key: employee.id.to_s, employee_name: employee.name, employment_type: employee.employment_type,
      started_at: Time.zone.parse(from), ended_at: to && Time.zone.parse(to), request_token: SecureRandom.uuid, source: source, location_id: location_id)
  end

  def tp_sign_in(user)
    delete logout_path if respond_to?(:cookies) && cookies.to_hash.any?
    post login_path, params: { email: user.email, password: PASSWORD }
    Current.tenant = @tenant
  end

  def tp_submitted_sheet!(employee, period_start, hours_by_day)
    sheet = employee.timesheets.create!(period_start: period_start, period_end: Date.parse(period_start.to_s) + 6)
    hours_by_day.each { |day, hours| sheet.entries.create!(worked_on: day, hours: hours, work_type: 'regular') }
    sheet.submit!
    sheet
  end
end
