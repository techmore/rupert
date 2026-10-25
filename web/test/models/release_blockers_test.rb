# frozen_string_literal: true

require 'test_helper'

class ReleaseBlockersTest < ActiveSupport::TestCase
  test 'the shipped config lists the open v0.2.1 blockers' do
    gate = ReleaseBlockers.load(ReleaseBlockers::PATH)
    assert_equal 'v0.2.1', gate.release
    assert_equal 'Release v0.2.1 blockers', gate.title
    assert_equal 'https://github.com/techmore/rupert/issues/326', gate.tracker_url
    ids = %w[google_drive_backup payroll_review tax_preparer_review wallet_payments pos_hardware branch_protection]
    assert_equal ids, gate.items.map(&:id)
    assert(gate.items.all? { |item| item.title.present? && item.needed.present? && item.issues.any? })
    assert_equal [[419, 'https://github.com/techmore/rupert/issues/419']], gate.items.first.issue_links.first(1)
  end

  test 'done items stop counting and an all-done gate is closed' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'gate.yml')
      File.write(path, { 'release' => 'v9', 'items' => [
        { 'id' => 'a', 'title' => 'A', 'needed' => 'x', 'issues' => [1], 'status' => 'done' },
        { 'id' => 'b', 'title' => 'B', 'needed' => 'y', 'issues' => ['2'], 'status' => 'open' }
      ] }.to_yaml)
      gate = ReleaseBlockers.load(path)
      assert_equal 1, gate.open_count
      assert_equal %w[b], gate.open_items.map(&:id)
      assert_equal %w[a], gate.done_items.map(&:id)
      assert_equal [2], gate.open_items.first.issues

      all_done = [{ 'id' => 'a', 'title' => 'A', 'issues' => [1], 'status' => 'done' }]
      File.write(path, { 'release' => 'v9', 'items' => all_done }.to_yaml)
      assert_not ReleaseBlockers.load(path).any_open?
    end
  end

  test 'an unknown status is an error, not a silently hidden blocker' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'gate.yml')
      File.write(path, { 'items' => [{ 'id' => 'a', 'title' => 'A', 'issues' => [1], 'status' => 'closed' }] }.to_yaml)
      assert_raises(ArgumentError) { ReleaseBlockers.load(path) }
    end
  end

  test 'only owners and platform administrators see it' do
    Current.tenant = tenants(:default_tenant)
    owner = users(:regular_user)
    assert ReleaseBlockers.visible_to?(owner)
    assert_not ReleaseBlockers.visible_to?(User.new(tenant: owner.tenant, role: 'manager'))
    assert_not ReleaseBlockers.visible_to?(User.new(tenant: owner.tenant, role: 'reader'))
    assert ReleaseBlockers.visible_to?(User.new(tenant: owner.tenant, role: 'super_admin'))
    assert_not ReleaseBlockers.visible_to?(nil)
  ensure
    Current.reset
  end
end
