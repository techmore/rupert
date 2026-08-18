# frozen_string_literal: true

require "test_helper"

class PlatformPushGuardTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
  end

  teardown do
    Setting.where(tenant_id: Current.tenant_id).delete_all
    Current.tenant = nil
  end

  test "Square defaults to frozen while its platform update is in progress" do
    assert PlatformPushGuard.frozen?("square")
    refute PlatformPushGuard.frozen?("shopify")
  end

  test "unfreeze persists so Square stops defaulting to frozen" do
    PlatformPushGuard.unfreeze!("square", actor: "ops@example.com")
    refute PlatformPushGuard.frozen?("square")
  end

  test "authorize! passes without approval windows (owner directive)" do
    PlatformPushGuard.unfreeze!("square", actor: "ops@example.com")
    assert PlatformPushGuard.authorize!("square", actor: "user")
  end

  test "one approval is not enough to open a window, but two distinct ones are" do
    PlatformPushGuard.unfreeze!("square", actor: "ops@example.com")

    PlatformPushGuard.approve!("square", email: "alice@example.com")
    refute PlatformPushGuard.window_open?("square")
    assert PlatformPushGuard.authorize!("square", actor: "user")

    PlatformPushGuard.approve!("square", email: "bob@example.com")
    assert PlatformPushGuard.window_open?("square")
    assert PlatformPushGuard.authorize!("square", actor: "user")
  end

  test "the same person approving twice does not count twice" do
    PlatformPushGuard.unfreeze!("square", actor: "ops@example.com")
    PlatformPushGuard.approve!("square", email: "alice@example.com")
    PlatformPushGuard.approve!("square", email: "alice@example.com")
    PlatformPushGuard.approve!("square", email: "ALICE@example.com")

    status = PlatformPushGuard.status("square")
    assert_equal 1, status[:approvals_needed]
    refute PlatformPushGuard.window_open?("square")
    assert PlatformPushGuard.authorize!("square", actor: "user")
  end

  test "a frozen platform no longer blocks pushes (guard removed)" do
    open_push_window!("square")
    PlatformPushGuard.freeze!("square", reason: "Square platform update in progress", actor: "ops@example.com")

    # Owner directive 2026-08-18: freeze no longer gates writes.
    assert PlatformPushGuard.authorize!("square", actor: "user")
    assert PlatformPushGuard.frozen?("square") # still reported as operator info
  end

  test "an expired window is reported closed but no longer locks pushes" do
    open_push_window!("square")
    blob = JSON.parse(Setting.find_by(key: "push_guard_square", tenant_id: Current.tenant_id).value)
    blob["window"]["expires_at"] = 1.minute.ago.iso8601
    Setting.find_by(key: "push_guard_square", tenant_id: Current.tenant_id).update!(value: JSON.generate(blob))

    refute PlatformPushGuard.window_open?("square")
    assert PlatformPushGuard.authorize!("square", actor: "user")
  end

  test "revoking an approval below the threshold closes the window" do
    open_push_window!("square")
    assert PlatformPushGuard.window_open?("square")

    PlatformPushGuard.revoke!("square", email: "approver-b@example.com")
    refute PlatformPushGuard.window_open?("square")
    assert PlatformPushGuard.authorize!("square", actor: "user")
  end

  test "unknown platforms are rejected" do
    assert_raises(ArgumentError) { PlatformPushGuard.authorize!("stripe", actor: "user") }
  end

  test "approvals are recorded per tenant" do
    open_push_window!("square")
    other = Tenant.create!(name: "Other", subdomain: "other#{SecureRandom.hex(4)}")
    Current.tenant = other

    refute PlatformPushGuard.window_open?("square")
    # Owner directive 2026-08-18: no approval window is needed to push.
    assert PlatformPushGuard.authorize!("square", actor: "user")
  ensure
    Current.tenant = tenants(:default_tenant)
  end
end
