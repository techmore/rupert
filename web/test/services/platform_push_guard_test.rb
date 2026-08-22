# frozen_string_literal: true

require 'test_helper'

class PlatformPushGuardTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    ENV.delete('PUSH_CONFIRM')
  end

  teardown do
    Setting.where(tenant_id: Current.tenant_id).delete_all
    ENV.delete('PUSH_CONFIRM')
    Current.tenant = nil
  end

  test 'Square defaults to frozen while its platform update is in progress' do
    assert PlatformPushGuard.frozen?('square')
    refute PlatformPushGuard.frozen?('shopify')
  end

  test 'unfreeze persists so Square stops defaulting to frozen' do
    PlatformPushGuard.unfreeze!('square', actor: 'ops@example.com')
    refute PlatformPushGuard.frozen?('square')
  end

  test 'authorize! refuses a write without explicit confirmation' do
    error = assert_raises(PlatformPushGuard::UnconfirmedError) do
      PlatformPushGuard.authorize!('square', actor: 'user')
    end
    assert_includes error.message, 'without explicit confirmation'
  end

  test 'authorize! accepts PUSH_CONFIRM=yes (ops one-offs)' do
    ENV['PUSH_CONFIRM'] = 'yes'
    assert PlatformPushGuard.authorize!('square', actor: 'ops')
  end

  test 'authorize! accepts an in-request confirmation set after a UI prompt' do
    Current.confirm_push!
    assert PlatformPushGuard.authorize!('square', actor: 'user')
    # CurrentAttributes is reset by the Rails executor between requests/jobs,
    # so the confirmation never leaks into the next action.
  end

  test 'unconfirmed attempts are recorded in the audit history' do
    begin
      PlatformPushGuard.authorize!('square', actor: 'user')
    rescue PlatformPushGuard::UnconfirmedError
      # expected
    end

    status = PlatformPushGuard.status('square')
    last = status[:history].last
    assert_equal 'confirm', last['action']
    assert_includes last['detail'], 'REFUSED'
  end
  test 'one approval is not enough to open a window, but two distinct ones are' do
    PlatformPushGuard.unfreeze!('square', actor: 'ops@example.com')

    PlatformPushGuard.approve!('square', email: 'alice@example.com')
    refute PlatformPushGuard.window_open?('square')

    PlatformPushGuard.approve!('square', email: 'bob@example.com')
    assert PlatformPushGuard.window_open?('square')
  end

  test 'the same person approving twice does not count twice' do
    PlatformPushGuard.unfreeze!('square', actor: 'ops@example.com')
    PlatformPushGuard.approve!('square', email: 'alice@example.com')
    PlatformPushGuard.approve!('square', email: 'alice@example.com')
    PlatformPushGuard.approve!('square', email: 'ALICE@example.com')

    status = PlatformPushGuard.status('square')
    assert_equal 1, status[:approvals_needed]
    refute PlatformPushGuard.window_open?('square')
  end

  test 'a frozen platform is reported but confirmation alone still gates writes' do
    open_push_window!('square')
    PlatformPushGuard.freeze!('square', reason: 'Square platform update in progress', actor: 'ops@example.com')

    assert PlatformPushGuard.frozen?('square') # operator info only
    # Freeze no longer blocks; only the explicit confirmation matters.
    ENV['PUSH_CONFIRM'] = 'yes'
    assert PlatformPushGuard.authorize!('square', actor: 'user')
  end

  test 'an expired window is reported closed' do
    open_push_window!('square')
    blob = JSON.parse(Setting.find_by(key: 'push_guard_square', tenant_id: Current.tenant_id).value)
    blob['window']['expires_at'] = 1.minute.ago.iso8601
    Setting.find_by(key: 'push_guard_square', tenant_id: Current.tenant_id).update!(value: JSON.generate(blob))

    refute PlatformPushGuard.window_open?('square')
  end

  test 'revoking an approval below the threshold closes the window' do
    open_push_window!('square')
    assert PlatformPushGuard.window_open?('square')

    PlatformPushGuard.revoke!('square', email: 'approver-b@example.com')
    refute PlatformPushGuard.window_open?('square')
  end

  test 'unknown platforms are rejected' do
    assert_raises(ArgumentError) { PlatformPushGuard.authorize!('stripe', actor: 'user') }
  end

  test 'approvals are recorded per tenant' do
    open_push_window!('square')
    other = Tenant.create!(name: 'Other', subdomain: "other#{SecureRandom.hex(4)}")
    Current.tenant = other

    refute PlatformPushGuard.window_open?('square')
  ensure
    Current.tenant = tenants(:default_tenant)
  end
end
