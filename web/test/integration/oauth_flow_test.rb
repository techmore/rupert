# frozen_string_literal: true

require "test_helper"

class OauthFlowTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: "OAuth Co", subdomain: "oauthco#{SecureRandom.hex(4)}")
    OauthAllowedDomain.create!(domain: "cybersecuritypilot.org")
  end

  teardown do
    Current.tenant = nil
  end

  test "authorize redirects to Google with a state token" do
    GoogleOauthService.stubs(:auth_url).returns("https://accounts.google.com/o/oauth2/auth?dummy=1")
    get google_auth_path
    assert_redirected_to("https://accounts.google.com/o/oauth2/auth?dummy=1")
    assert_not_nil session[:oauth_state]
  end

  test "callback signs in an existing super admin from an allowed domain" do
    sean = User.create!(email: "sean.dolbec@cybersecuritypilot.org", name: "Sean Dolbec", role: "super_admin", password: "password123")
    GoogleOauthService.stubs(:auth_url).returns("https://accounts.google.com/")
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
      .with("code123", redirect_uri: google_callback_url)
      .returns("email" => "sean.dolbec@cybersecuritypilot.org", "name" => "Sean Dolbec")

    get google_callback_path, params: { code: "code123", state: state }
    assert_redirected_to(root_path)
    assert_equal sean.id, session[:user_id]
  end

  test "callback auto-provisions a reader for a new allowed-domain user" do
    GoogleOauthService.stubs(:auth_url).returns("https://accounts.google.com/")
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
      .with("code123", redirect_uri: google_callback_url)
      .returns("email" => "new.person@cybersecuritypilot.org", "name" => "New Person")

    get google_callback_path, params: { code: "code123", state: state }
    assert_redirected_to(root_path)
    created = User.find_by(email: "new.person@cybersecuritypilot.org")
    assert_not_nil created
    assert_equal "reader", created.role
    assert_equal session[:user_id], created.id
  end

  test "callback rejects email on a non-allowed domain" do
    GoogleOauthService.stubs(:auth_url).returns("https://accounts.google.com/")
    get google_auth_path
    state = session[:oauth_state]

    GoogleOauthService.expects(:exchange_code!)
      .with("code123", redirect_uri: google_callback_url)
      .returns("email" => "someone@evil.com", "name" => "Someone")

    get google_callback_path, params: { code: "code123", state: state }
    assert_redirected_to(login_path)
    assert_nil User.find_by(email: "someone@evil.com")
  end

  test "authorize records a Google attempt in the access log" do
    GoogleOauthService.stubs(:auth_url).returns("https://accounts.google.com/o/oauth2/auth?dummy=1")
    get google_auth_path
    assert_redirected_to("https://accounts.google.com/o/oauth2/auth?dummy=1")
    log = AccessLog.order(:id).last
    assert_equal "google", log.source
    assert_equal "attempt", log.status
    assert_equal "127.0.0.1", log.ip
  end

  test "callback rejects a mismatched state" do
    GoogleOauthService.expects(:exchange_code!).never
    get google_callback_path, params: { code: "code123", state: "wrong-state" }
    assert_redirected_to(login_path)
    log = AccessLog.order(:id).last
    assert_equal "google", log.source
    assert_equal "failure", log.status
    assert_includes log.detail, "state check"
  end
end
