# frozen_string_literal: true

# Browser sign-in for integration tests, through the real login form.
#
#   sign_in users(:admin_user)
#   sign_in @worker, password: 'wrong'
#
# Without a password it uses the one the user was created with in tests:
# 'password' for fixture users, 'password123' for users a test creates.
# A test that needs more (log out first, restore Current.tenant, assert the
# redirect) can still define its own sign_in; a local method wins.
module SignInHelper
  TEST_PASSWORDS = %w[password password123].freeze

  def sign_in(user, password: nil)
    password ||= TEST_PASSWORDS.find { |candidate| user.authenticate(candidate) } || TEST_PASSWORDS.first
    post login_path, params: { email: user.email, password: password }
  end
end
