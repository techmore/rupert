# frozen_string_literal: true

# Kill switch for the staff mobile app API (/api/v1/employee_*), #436.
# Off in production unless RUPERT_EMPLOYEE_APP_ENABLED=1: while off, new
# sign-ins are refused and every existing app token fails closed.
# The /employee web pages use normal web sign-in and are not affected.
Rails.application.config.x.employee_app_enabled =
  ENV.fetch('RUPERT_EMPLOYEE_APP_ENABLED') { Rails.env.production? ? '0' : '1' } == '1'
