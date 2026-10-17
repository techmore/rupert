# Explicit operator task; never invoked by migrations or normal sign-in.
namespace :employee_pay do
  desc 'Create an isolated fake employee and exact-email Google login: employee_pay:demo[email,workspace]'
  task :demo, %i[email workspace] => :environment do |_task, args|
    email = args[:email].to_s.strip.downcase
    raise ArgumentError, 'Provide an email and an existing workspace subdomain' unless email.match?(URI::MailTo::EMAIL_REGEXP) && args[:workspace].present?

    tenant = Tenant.find_by!(subdomain: args[:workspace])
    Current.set(tenant: tenant) do
      User.transaction do
        user = User.find_by(email: email)
        identity = GoogleLoginIdentity.find_by(email: email)
        raise 'This email is already an alias for another account; preserve that login and resolve explicitly first' if identity && identity.user_id != user&.id
        raise 'Existing account belongs to a different workspace' if user && user.tenant_id != tenant.id
        user ||= User.create!(tenant: tenant, email: email, name: 'Demo Employee (fake)', role: 'employee', password: SecureRandom.hex(32))
        worker = People::Employee.find_by(user_id: user.id)
        raise 'Existing employee has real data; refusing to replace it with a demo' if worker && worker.source != 'demo_pay'
        worker ||= People::Employee.create!(user: user, first_name: 'Demo', last_name: 'Employee (fake)',
          email: email, source: 'demo_pay', external_id: "demo-user-#{user.id}", employment_type: 'unspecified',
          notes: 'DEMO DATA ONLY. Fake employee for illustrating bonus-inclusive hourly earnings. No payroll, pay rates or timesheet entries are seeded.')
        GoogleLoginIdentity.find_or_create_by!(email: email) { |record| record.user = user }
        puts 'Demo employee ready. Sign in with the specified Google account and open /employee. Synthetic earnings are read-only and never entered into payroll.'
      end
    end
  end
end
