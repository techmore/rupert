# frozen_string_literal: true

require 'test_helper'

# The top-bar release gate (shared/_header_gate): owners and platform administrators see the
# open release blockers from config/release_blockers.yml; staff never do.
class ReleaseGateTest < ActionDispatch::IntegrationTest
  ISSUES = [419, 418, 420, 421, 424, 425, 472, 479, 478, 206].freeze

  setup do
    Current.tenant = tenants(:default_tenant)
    @owner = users(:regular_user)
  end

  teardown { Current.reset }

  test 'an owner sees the gate with its six blockers and their GitHub issues' do
    post login_path, params: { email: @owner.email, password: 'password' }
    get sales_path
    assert_response :success
    assert_select '[data-release-gate] button[aria-controls="release-gate-panel"][aria-expanded="false"]'
    assert_select '[data-release-gate-open="6"]', text: '6'
    assert_select '#release-gate-panel.hidden' do
      assert_select '#release-gate-title', text: 'Release v0.2.1 blockers'
      assert_select '[data-release-blocker]', count: 6
      assert_select '[data-release-blocker="google_drive_backup"]', text: /Google Drive backup consent/
      ISSUES.each do |number|
        assert_select "a[href='https://github.com/techmore/rupert/issues/#{number}'][target='_blank'][rel='noopener']"
      end
      assert_select "a[href='https://github.com/techmore/rupert/issues/326']", text: /release tracker/
    end
  end

  test 'the style guide shows the release gate component' do
    post login_path, params: { email: @owner.email, password: 'password' }
    get system_style_guide_path
    assert_response :success
    assert_select '.gate-menu[aria-label="Sample release blockers"] .gate-item', count: 3
  end

  test 'a platform administrator sees the gate' do
    @owner.update!(role: 'super_admin')
    post login_path, params: { email: @owner.email, password: 'password' }
    get sales_path
    assert_select '[data-release-gate]', count: 1
  end

  test 'staff and readers never see the gate' do
    %w[manager reader].each do |role|
      user = User.create!(tenant: Current.tenant, email: "gate-#{role}@example.com", role: role,
        password: 'password123')
      post login_path, params: { email: user.email, password: 'password123' }
      get root_path
      assert_select '[data-release-gate]', count: 0
      assert_select "a[href^='https://github.com/techmore/rupert/issues/']", count: 0
      delete logout_path
    end
  end

  test 'the gate hides when every blocker is done' do
    item = ReleaseBlockers::Item.new(id: 'a', title: 'A', needed: 'x', issues: [1], status: 'done')
    done = ReleaseBlockers.new(release: 'v0.2.1', tracker_issue: 326, items: [item])
    ReleaseBlockers.stub(:current, done) do
      post login_path, params: { email: @owner.email, password: 'password' }
      get sales_path
      assert_select '[data-release-gate]', count: 0
    end
  end
end
