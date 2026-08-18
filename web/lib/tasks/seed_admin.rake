# frozen_string_literal: true

# Instance-start admin provisioning. Creates (or resets) a super admin and
# prints the credentials so the operator can hand them to the customer.
#
#   bin/rails rupert:seed_admin
#   SEED_ADMIN_EMAIL=owner@example.com bin/rails rupert:seed_admin   # pick email
#   SEED_ADMIN_EMAIL=... SEED_ADMIN_RESET=1 bin/rails rupert:seed_admin  # force new password
namespace :rupert do
  desc "Create/reset the super admin and print its login credentials"
  task seed_admin: :environment do
    email = (ENV["SEED_ADMIN_EMAIL"].presence || "admin@herbalhealers.com").downcase
    reset = ENV["SEED_ADMIN_RESET"].present?

    admin = User.find_by(email: email)

    if admin && !reset
      puts "Super admin already exists: #{admin.email}"
      puts "To rotate the password, rerun with SEED_ADMIN_RESET=1."
      next
    end

    password = SecureRandom.alphanumeric(14)
    admin ||= User.new(email: email, role: "super_admin")
    admin.name ||= "Platform Admin"
    admin.role = "super_admin"
    admin.password = password
    admin.save!

    credentials = <<~TEXT

      Super admin ready
      URL:      #{ENV.fetch("HOST", "http://localhost:3000")}
      Email:    #{admin.email}
      Password: #{password}

      Sign in, then create the first customer under Tenants > New tenant
      to give it its own subdomain.
    TEXT

    if $stdout.isatty
      puts credentials
    else
      # Non-interactive (cron/CI/scripts): never leak the password into logs.
      # Write it to a 0600 file instead.
      path = Rails.root.join("tmp", "seed_admin_credentials.txt")
      File.write(path, credentials, perm: 0o600)
      puts "Super admin created. Credentials written to #{path} (mode 0600)."
    end
  end
end
