# frozen_string_literal: true

require 'test_helper'

# What App Review sees in the iPhone app (ios/): no beta-looking build strip, and the session tag
# the app uses to restart its tabs after a sign-in or sign-out (SessionWatcher.swift).
class NativeAppReviewTest < ActionDispatch::IntegrationTest
  NATIVE_UA = {
    'User-Agent' => 'Mozilla/5.0 (iPhone) Rupert iOS/1.0.0 (1); Hotwire Native iOS; Turbo Native iOS'
  }.freeze
  TOTALS = {
    'schema_version' => 1, 'revision' => 'd' * 40, 'version' => '0.2.0', 'as_of' => '2026-10-21T12:00:00Z',
    'base_revision' => 'b' * 40, 'source_lines' => 120_000,
    'nightly' => { 'patch_commits' => 42, 'lines_added' => 1000, 'lines_deleted' => 200, 'confirmed_bugs_fixed' => 4 },
    'cumulative' => { 'patch_commits' => 500, 'lines_added' => 130_000, 'lines_deleted' => 10_000 }
  }.freeze

  setup do
    BuildInfo.stubs(:current).returns(BuildInfo.new(revision: 'd' * 40, release_totals: TOTALS))
    @tenant = Tenant.create!(name: 'Review Co', subdomain: "reviewco#{SecureRandom.hex(4)}")
    host! "#{@tenant.subdomain}.example.com"
    @admin = User.create!(
      email: "owner-#{SecureRandom.hex(3)}@reviewco.example", name: 'Owner', role: 'admin',
      password: 'password123', tenant_id: @tenant.id
    )
  end

  teardown { Current.reset }

  test 'the app sign-in page has no build strip but keeps the build header' do
    get login_path, headers: NATIVE_UA
    assert_response :success
    assert_select '[aria-label="Rupert build version"]', count: 0
    refute_includes response.body, 'Nightly:'
    assert_equal 'd' * 40, response.headers['X-Rupert-Build']
  end

  test 'browsers still see the signed-out build strip' do
    get login_path
    assert_select '[aria-label="Rupert build version"]', count: 1
    assert_includes response.body, 'Nightly:'
  end

  test 'the app account menu shows the build without nightly source totals' do
    post login_path, params: { email: @admin.email, password: 'password123' }
    get root_path, headers: NATIVE_UA
    assert_response :success
    assert_select '[aria-label="Rupert build version"]', count: 1
    assert_select 'details[data-build-totals]', count: 0
    assert_select '[data-build-totals-unavailable]', count: 0
    refute_includes response.body, 'Nightly:'
  end

  test 'app pages say whether the person is signed in' do
    get login_path, headers: NATIVE_UA
    assert_select 'meta[name="rupert-session"][content="signed-out"]', count: 1

    get privacy_policy_path, headers: NATIVE_UA
    assert_select 'meta[name="rupert-session"][content="signed-out"]', count: 1

    post login_path, params: { email: @admin.email, password: 'password123' }, headers: NATIVE_UA
    follow_redirect!(headers: NATIVE_UA.dup)
    assert_select 'meta[name="rupert-session"][content="signed-in"]', count: 1

    # A public page opened while signed in must not look like a sign-out, or the app would restart its tabs.
    get privacy_policy_path, headers: NATIVE_UA
    assert_select 'meta[name="rupert-session"][content="signed-in"]', count: 1

    delete logout_path, headers: NATIVE_UA
    follow_redirect!(headers: NATIVE_UA.dup)
    assert_select 'meta[name="rupert-session"][content="signed-out"]', count: 1
  end

  test 'browsers do not get the app session tag' do
    get login_path
    assert_select 'meta[name="rupert-session"]', count: 0
  end
end
