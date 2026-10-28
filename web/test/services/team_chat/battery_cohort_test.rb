# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class TeamChatBatteryCohortTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @item = TeamChat::Battery::Item.new(id: 'q1', cadence: 'daily', question: 'How much?', checks: [], expect: 'Use the reference', needs: [])
  end

  teardown { Current.reset }

  test 'encrypted cohort keeps the same reference and rejects changed data and questions' do
    cohort = TeamChat::Battery::Cohort.capture(user: @user, items: [@item]) { 'private synthetic evidence' }
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'cohort')
      cohort.save_file(path)
      refute_includes File.binread(path), 'private synthetic evidence'
      assert_equal 0o600, File.stat(path).mode & 0o777
      loaded = TeamChat::Battery::Cohort.load_file(path, user: @user)
      assert_equal cohort.id, loaded.id
      assert_equal 'private synthetic evidence', loaded.reference(@item) { 'private synthetic evidence' }
      assert_raises(TeamChat::Battery::Grader::Error) { loaded.reference(@item) { 'changed' } }
      changed = @item.dup
      changed.question = 'Different question?'
      assert_raises(TeamChat::Battery::Grader::Error) { loaded.reference(changed) { 'private synthetic evidence' } }
      assert_raises(Errno::EEXIST) { loaded.save_file(path) }
    end
  end

  test 'records missing evidence and refuses another user or date' do
    cohort = TeamChat::Battery::Cohort.capture(user: @user, items: [@item]) { raise TeamChat::Battery::Grader::Error, 'missing data' }
    assert_equal 1, cohort.ungradable
    assert_raises(TeamChat::Battery::Grader::Error) { cohort.reference(@item) { 'anything' } }
    assert_not cohort.for_user?(Struct.new(:id, :tenant_id).new(@user.id + 1, @tenant.id))
    dated = TeamChat::Battery::Cohort.capture(user: @user, items: [@item]) { 'a' }
    travel_to 1.day.from_now do
      assert_raises(TeamChat::Battery::Grader::Error) { dated.reference(@item) { 'a' } }
    end
  end

  test 'rejects duplicate question IDs' do
    assert_raises(TeamChat::Battery::Cohort::Error) do
      TeamChat::Battery::Cohort.capture(user: @user, items: [@item, @item]) { 'a' }
    end
  end
end
