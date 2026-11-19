# frozen_string_literal: true

require 'test_helper'

# Rupert lists the iPhone app's tabs an account can open, so the app hides the ones that would
# only refuse (ApplicationHelper#native_app_tabs, ios/Sources/Rupert/Tabs.swift). The list is a
# convenience: each page still makes its own permission check.
class NativeAppTabsTest < ActionDispatch::IntegrationTest
  NATIVE_UA = { 'HTTP_USER_AGENT' => 'Rupert iOS/1.1.0 (1); Hotwire Native iOS; Turbo Native iOS; bridge-components: []' }.freeze
  PATHS = { 'time' => '/employee', 'home' => '/login', 'chat' => '/chat', 'ask' => '/ask_rupert', 'inbox' => '/notifications' }.freeze

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  test 'a staff account is offered Time and Notifications, and each opens' do
    sign_in_as('employee', worker: true)
    get employee_app_path, headers: NATIVE_UA
    assert_response :success
    assert_equal %w[time inbox], listed_tabs
    assert_every_listed_tab_opens
    # The tabs it is not offered are the ones that refuse it.
    get '/chat', headers: NATIVE_UA
    assert_redirected_to employee_app_path
    get '/ask_rupert', headers: NATIVE_UA
    assert_redirected_to employee_app_path
  end

  test 'cashier, shift lead and manager keep Home but are not offered Team Chat or Ask Rupert' do
    %w[cashier shift_leader manager].each do |role|
      sign_in_as(role)
      get notifications_path, headers: NATIVE_UA
      assert_response :success
      assert_equal %w[time home inbox], listed_tabs, role
      assert_every_listed_tab_opens
      get '/chat', headers: NATIVE_UA
      assert_response :forbidden, "#{role}: Team Chat refuses, so it is not a tab"
      get '/ask_rupert', headers: NATIVE_UA
      assert_response :forbidden, "#{role}: Ask Rupert refuses, so it is not a tab"
    end
  end

  test 'the owner is offered every tab, and each opens' do
    sign_in users(:regular_user)
    get notifications_path, headers: NATIVE_UA
    assert_equal %w[time home chat ask inbox], listed_tabs
    assert_every_listed_tab_opens
  end

  test 'signed-out pages and browsers carry no tab list' do
    get login_path, headers: NATIVE_UA
    assert_select 'meta[name="rupert-tabs"]', count: 0
    sign_in users(:regular_user)
    get notifications_path
    assert_select 'meta[name="rupert-tabs"]', count: 0
  end

  test 'a signed-in staff account can still fetch the app’s navigation rules' do
    get '/native/ios/path-configuration.json'
    assert_response :success
    sign_in_as('employee', worker: true)
    get '/native/ios/path-configuration.json'
    assert_response :success
    assert response.parsed_body['rules'].any?
  end

  private

  def sign_in_as(role, worker: false)
    delete logout_path
    user = User.create!(tenant: @tenant, email: "#{role}-tabs@example.com", password: 'password123', role: role)
    People::Employee.create!(first_name: 'Tab', last_name: role.titleize, user: user) if worker
    sign_in user
    Current.tenant = @tenant
    user
  end

  def listed_tabs
    css_select('meta[name="rupert-tabs"]').first&.[]('content').to_s.split
  end

  # A listed tab must open: a page, or a redirect that is not a refusal.
  def assert_every_listed_tab_opens
    listed_tabs.each do |tab|
      get PATHS.fetch(tab), headers: NATIVE_UA
      follow_redirect!(headers: NATIVE_UA.dup) while response.redirect?
      assert_response :success, "tab #{tab}"
      assert_no_match(/permission|can use POS/, flash[:alert].to_s, "tab #{tab} refused")
    end
  end
end
