# frozen_string_literal: true

# Shared setup for the release-gate walkthroughs (test/acceptance/*_walkthrough_test.rb, #422 #424 #411).
#
# Each walkthrough drives the real routes (web pages and the staff app API) with synthetic people in a fresh
# workspace, asserts every step and keeps a step log. Run one with its evidence printed:
#
#   WALKTHROUGH_LOG=1 bin/rails test test/acceptance/timesheet_lifecycle_walkthrough_test.rb
#
# Everything here is fictional: names, emails and amounts. Nothing reads or writes an outside system.
module WalkthroughHelper
  PASSWORD = 'walkthrough-pass-1'

  def self.included(base)
    base.teardown do
      if ENV['WALKTHROUGH_LOG'].present? && @steps
        puts "\n== #{self.class.name}##{name}"
        @steps.each_with_index { |(label, result), i| puts format('%2d. %s => %s', i + 1, label, result) }
      end
      Current.reset
    end
  end

  # Records one step and its observed result for the evidence log.
  def step(label, result = 'ok')
    (@steps ||= []) << [label, result]
  end

  def synthetic_workspace(name)
    @tenant = Tenant.create!(name: name, subdomain: "walk#{SecureRandom.hex(4)}")
    Current.tenant = @tenant
    @tenant
  end

  def person(email, role, first, last, rate_cents: nil)
    user = User.create!(tenant: @tenant, email: email, name: "#{first} #{last}", role: role, password: PASSWORD)
    employee = People::Employee.create!(first_name: first, last_name: last, user: user, employment_type: 'part_time')
    People::PayRate.create!(employee: employee, pay_type: 'hourly', hourly_rate_cents: rate_cents, pay_frequency: 'weekly', effective_on: '2026-01-01') if rate_cents
    [user, employee]
  end

  # Browser sign-in (one session per integration runner; signing in again switches the person).
  def sign_in(user)
    delete logout_path if cookies.to_hash.any?
    post login_path, params: { email: user.email, password: PASSWORD }
    assert_response :redirect
    Current.tenant = @tenant
  end

  # Staff app sign-in: returns the bearer header for /api/v1/employee/*.
  def app_login(user)
    post '/api/v1/employee/session', params: { email: user.email, password: PASSWORD, device_name: 'Walkthrough phone' }, as: :json
    assert_response :created
    Current.tenant = @tenant
    { 'Authorization' => "Bearer #{response.parsed_body.fetch('token')}" }
  end

  def at(local_time, &)
    travel_to(Time.zone.parse(local_time), &)
  end

  def tenant_scope(&)
    Current.set(tenant: @tenant, &)
  end
end
