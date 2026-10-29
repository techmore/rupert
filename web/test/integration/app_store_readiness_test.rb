# frozen_string_literal: true

require 'test_helper'

# What App Store review needs from the website: public privacy and support pages, deleting your own
# account (guideline 5.1.1(v)), and no sign-up or subscription purchase inside the iPhone app (3.1.1).
class AppStoreReadinessTest < ActionDispatch::IntegrationTest
  APP = { 'User-Agent' => 'Mozilla/5.0 (iPhone) Rupert iOS/1.0.0 (1); Hotwire Native iOS; Turbo Native iOS' }.freeze

  setup do
    @tenant = Tenant.create!(name: 'Review Co', subdomain: "reviewco#{SecureRandom.hex(4)}")
    @admin = User.create!(email: 'owner@reviewco.test', name: 'Owner Person', role: 'admin',
      password: 'password123', tenant_id: @tenant.id)
  end

  teardown { Current.reset }

  def sign_in(user = @admin, headers: {})
    post login_path, params: { email: user.email, password: 'password123' }, headers: headers
  end

  test 'privacy policy and support are public and load Turbo, so they also open in the app' do
    get privacy_policy_path
    assert_response :success
    assert_select 'h1', 'Privacy policy'
    assert_includes response.body, 'Delete my account'
    get support_path, headers: APP
    assert_response :success
    assert_select 'h1', 'Support'
    assert_select "a[href='mailto:support@rupertpos.com']"
    assert_select 'script[type=importmap]'
  end

  test 'the support address can be set per deployment' do
    ENV['RUPERT_SUPPORT_EMAIL'] = 'help@example.test'
    get support_path
    assert_select "a[href='mailto:help@example.test']"
  ensure
    ENV.delete('RUPERT_SUPPORT_EMAIL')
  end

  test 'the app sign-in page offers no sign-up; the website still does' do
    get login_path, headers: APP
    assert_select "a[href='#{start_path}']", count: 0
    assert_includes response.body, 'Rupert accounts are set up by your business.'
    assert_select "a[href='#{privacy_policy_path}']"
    get login_path
    assert_select "a[href='#{start_path}']", 'Create a free account'
  end

  test 'subscriptions are not shown or sold inside the app' do
    sign_in(headers: APP)
    get root_path, headers: APP
    assert_select "a[href='#{billing_path}']", count: 0
    assert_select "a[href='#{delete_account_path}']", 'Delete my account'
    get billing_path, headers: APP
    assert_response :not_found
    post billing_checkout_path, params: { plan: 'monthly', accepted: '1' }, headers: APP
    assert_response :not_found
    get root_path
    assert_select "a[href='#{billing_path}']"
  end

  test 'a person deletes their own account: personal details and sign-in are gone, the row stays' do
    other = User.create!(email: 'staff@reviewco.test', name: 'Staff', role: 'employee', password: 'password123', tenant_id: @tenant.id)
    sign_in
    get delete_account_path
    assert_response :success
    assert_select 'h1', 'Delete my account'

    delete own_account_path, params: { confirmation: 'nope' }
    assert_response :unprocessable_entity
    assert @admin.reload.active?

    delete own_account_path, params: { confirmation: 'delete' }
    assert_redirected_to login_path
    @admin.reload
    assert_not @admin.active?
    assert_equal 'Deleted user', @admin.name
    assert @admin.email.end_with?('@deleted.invalid')
    assert_not @admin.authenticate('password123')
    assert other.reload.active?

    get delete_account_path
    assert_redirected_to login_path
    post login_path, params: { email: 'owner@reviewco.test', password: 'password123' }
    assert_response :unprocessable_entity
  end

  test 'the last platform administrator cannot delete their account' do
    root = User.create!(email: 'root@reviewco.test', name: 'Root', role: 'super_admin', password: 'password123', tenant_id: @tenant.id)
    User.where(role: 'super_admin').where.not(id: root.id).update_all(active: false)
    sign_in(root)
    delete own_account_path, params: { confirmation: 'DELETE' }
    assert_response :unprocessable_entity
    assert root.reload.active?
  end

  test "the app's Search tab is a page; the palette still gets JSON" do
    sign_in(headers: APP)
    get search_path, headers: APP
    assert_response :success
    assert_select 'h1', 'Search'
    assert_includes response.body, 'Search your workspace.'
    get search_path, params: { q: 'zzzz-nothing' }, headers: APP
    assert_includes response.body, 'No matches'
    get search_path, params: { q: 'zzzz-nothing' }, headers: APP.merge('Accept' => 'application/json', 'X-Requested-With' => 'XMLHttpRequest')
    assert_equal [], response.parsed_body
    get search_path, params: { q: 'zzzz-nothing' }
    assert_equal [], response.parsed_body
  end

  test "the app's Ask Rupert tab is a page that opens the chat; the website keeps its redirect" do
    sign_in(headers: APP)
    get ask_rupert_path, headers: APP
    assert_response :success
    assert_select '[data-ask-rupert-open-on-load]'
    get ask_rupert_path
    assert_redirected_to learning_index_path
  end

end
