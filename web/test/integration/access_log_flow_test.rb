# frozen_string_literal: true

require "test_helper"

class AccessLogFlowTest < ActionDispatch::IntegrationTest
  setup do
    @subdomain = "aclco#{SecureRandom.hex(4)}"
    @tenant = Tenant.create!(name: "ACL Co", subdomain: @subdomain)
    @admin = User.create!(email: "acl-admin@example.com", password: "password123", role: "admin", name: "Admin", tenant_id: @tenant.id)
    Current.tenant = @tenant
    host!("#{@subdomain}.example.com")
  end

  teardown do
    Current.tenant = nil
  end

  test "failed and successful password logins are recorded with email and IP" do
    post login_path, params: { email: @admin.email, password: "wrong" }
    assert_response :unprocessable_entity

    post login_path, params: { email: @admin.email, password: "password123" }
    assert_redirected_to(root_path)

    logs = AccessLog.order(:created_at)
    assert_equal 2, logs.count
    assert_equal "failure", logs.first.status
    assert_equal "password", logs.first.source
    assert_equal @admin.email, logs.first.email
    assert_equal "example.com", logs.first.domain
    assert_equal "127.0.0.1", logs.first.ip
    assert_equal "success", logs.last.status
    assert_equal @admin.id, logs.last.user_id
    assert_equal "example.com", logs.last.domain
  end

  test "sign out is logged" do
    post login_path, params: { email: @admin.email, password: "password123" }
    delete logout_path
    assert_equal "logout", AccessLog.last.source
    assert_equal "success", AccessLog.last.status
  end

  test "an admin can view the access log with filters" do
    post login_path, params: { email: @admin.email, password: "password123" }
    post login_path, params: { email: "nobody@example.com", password: "wrong" }

    get access_logs_path
    assert_response :success
    assert_includes response.body, @admin.email
    assert_includes response.body, "nobody@example.com"
    assert_includes response.body, "127.0.0.1"

    get access_logs_path, params: { status: "failure" }
    assert_includes response.body, "nobody@example.com"
    assert_includes response.body, "unknown email"
    assert_not_includes response.body, ">success<"
  end

  test "a reader cannot view the access log" do
    reader = User.create!(email: "acl-reader@example.com", password: "password123", role: "reader", name: "Reader", tenant_id: @tenant.id)
    post login_path, params: { email: reader.email, password: "password123" }

    get access_logs_path
    assert_redirected_to(root_path)
  end

  test "too many failed attempts from one IP triggers rate limiting" do
    (LoginThrottle::IP_FAILURES + 1).times do
      post login_path, params: { email: @admin.email, password: "wrong" }
      assert_response :unprocessable_entity
    end

    post login_path, params: { email: @admin.email, password: "wrong" }
    assert_response :unprocessable_entity
    assert_includes response.body, "Too many failed sign-in attempts"
    assert_equal "rate limited", AccessLog.unscoped.order(:id).last.detail

    # Even a correct password is refused while throttled.
    post login_path, params: { email: @admin.email, password: "password123" }
    assert_response :unprocessable_entity
    assert_includes response.body, "Too many failed sign-in attempts"
  end
end
