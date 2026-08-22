# frozen_string_literal: true

require 'test_helper'

class LoginThrottleTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Current.tenant = nil
  end

  def add_failure(ip:, email:)
    AccessLog.create!(tenant_id: Current.tenant_id, source: 'password', status: 'failure',
                      ip: ip, email: email, detail: 'invalid password')
  end

  test 'is not blocked with no failures' do
    refute LoginThrottle.blocked?(ip: '1.1.1.1', email: 'a@example.com')
  end

  test 'blocks an IP after too many failures' do
    (LoginThrottle::IP_FAILURES - 1).times { add_failure(ip: '9.9.9.9', email: 'x@example.com') }
    refute LoginThrottle.blocked?(ip: '9.9.9.9')
    add_failure(ip: '9.9.9.9', email: 'y@example.com')
    assert LoginThrottle.blocked?(ip: '9.9.9.9')
    assert_operator LoginThrottle.lockout_minutes(ip: '9.9.9.9'), :>=, 1
  end

  test 'blocks an email after fewer failures than an IP' do
    LoginThrottle::EMAIL_FAILURES.times { add_failure(ip: '8.8.8.8', email: 'target@example.com') }
    assert LoginThrottle.blocked?(email: 'target@example.com')
  end

  test 'rate-limited rows do not extend the lockout' do
    (LoginThrottle::IP_FAILURES + 5).times do
      AccessLog.create!(tenant_id: Current.tenant_id, source: 'password', status: 'failure',
                        ip: '7.7.7.7', email: 'x@example.com', detail: 'rate limited')
    end
    refute LoginThrottle.blocked?(ip: '7.7.7.7')
  end
end
