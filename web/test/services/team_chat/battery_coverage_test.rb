# frozen_string_literal: true

require 'test_helper'

class TeamChatBatteryCoverageTest < ActiveSupport::TestCase
  FakeTool = Class.new do
    class << self
      attr_accessor :tool_name, :available, :data

      def read_only = true
      def available_to?(_token) = available
      def new(token:) = Instance.new(token, data)
    end

    class Instance
      def initialize(_token, data) = @data = data
      def call(_args) = Mcp::Result.new(text: 'Not printed', data: @data)
    end
  end

  FakeRegistry = Class.new do
    def initialize(tool) = @tool = tool

    def find(name)
      @tool if name == @tool.tool_name
    end
  end

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
  end

  teardown { Current.reset }

  test 'checks declared paths without printing tool values and ignores an empty wildcard collection' do
    FakeTool.tool_name = 'fixture_read'
    FakeTool.available = true
    FakeTool.data = { rows: [{ name: 'Private product name', status: 'open' }] }
    item = TeamChat::Battery::Item.new(id: 'x', question: 'fixture', checks: ['fixture_read'], needs: %w[fixture_read:rows[].name fixture_read:rows[].path])

    report = TeamChat::BatteryCoverage.new(user: @user, items: [item], registry: FakeRegistry.new(FakeTool)).call

    assert_equal [:ok], report.questions.first.calls.map(&:status)
    assert_equal ['fixture_read:rows[].path'], report.questions.first.missing_needs
    assert_includes report.markdown, 'fixture_read: ok'
    refute_includes report.markdown, 'Private product name'
  end

  test 'counts empty read-only results without treating a wildcard with no rows as a missing field' do
    FakeTool.tool_name = 'fixture_read'
    FakeTool.available = true
    FakeTool.data = { rows: [] }
    item = TeamChat::Battery::Item.new(id: 'x', question: 'fixture', checks: ['fixture_read'], needs: ['fixture_read:rows[].name'])

    report = TeamChat::BatteryCoverage.new(user: @user, items: [item], registry: FakeRegistry.new(FakeTool)).call

    assert_equal [:empty], report.questions.first.calls.map(&:status)
    assert_empty report.questions.first.missing_needs
    assert report.passed?
  end

  test 'nullable needs permit explicit null but still require the key' do
    FakeTool.tool_name = 'fixture_read'
    FakeTool.available = true
    FakeTool.data = { rows: [{ quantity: nil }] }
    item = TeamChat::Battery::Item.new(id: 'x', question: 'fixture', checks: ['fixture_read'],
      needs: ['fixture_read:rows[].quantity?', 'fixture_read:rows[].missing?'])

    report = TeamChat::BatteryCoverage.new(user: @user, items: [item], registry: FakeRegistry.new(FakeTool)).call

    assert_equal ['fixture_read:rows[].missing?'], report.questions.first.missing_needs
  end

  test 'filtered needs require the named row and accept an explicit zero' do
    coverage = TeamChat::BatteryCoverage.new(user: @user, items: [])
    path = 'items[title=Timesheets awaiting approval].count'
    unrelated = { items: [{ title: 'Other check', count: 4 }] }
    matching = { items: [{ title: 'Other check', count: 4 }, { title: 'Timesheets awaiting approval', count: 0 }] }
    refute coverage.need_present?(unrelated, path)
    refute coverage.need_present?({ items: [] }, path)
    assert coverage.need_present?(matching, path)
    refute coverage.need_present?({ items: [{ title: 'Timesheets awaiting approval' }] }, path)
  end

  test 'a selected compliance reference contains only its named row' do
    coverage = TeamChat::BatteryCoverage.new(user: @user, items: [])
    data = { items: [{ title: 'Other', status: 'ok' }, { title: 'Target', status: 'watch', count: 0 }] }
    check = { 'tool' => 'compliance_check', 'select_title' => 'Target' }
    assert_equal({ items: [{ title: 'Target', status: 'watch', count: 0 }] }, coverage.reference_data(data, check))
    assert_equal({ items: [] }, coverage.reference_data(data, check.merge('select_title' => 'Missing')))
    refute coverage.need_present?(coverage.reference_data(data, check.merge('select_title' => 'Missing')), 'items[title=Missing].status')
  end

  test 'an unavailable check is an error' do
    FakeTool.tool_name = 'fixture_read'
    FakeTool.available = false
    FakeTool.data = {}
    item = TeamChat::Battery::Item.new(id: 'x', question: 'fixture', checks: ['fixture_read'], needs: [])

    report = TeamChat::BatteryCoverage.new(user: @user, items: [item], registry: FakeRegistry.new(FakeTool)).call

    assert_equal 1, report.errors
    refute report.passed?
  end

  test 'a compliance item that could not be checked is an error' do
    FakeTool.tool_name = 'fixture_read'
    FakeTool.available = true
    FakeTool.data = { items: [{ title: 'Finance could not be checked', status: 'unknown' }] }
    item = TeamChat::Battery::Item.new(id: 'x', question: 'fixture', checks: ['fixture_read'], needs: [])

    report = TeamChat::BatteryCoverage.new(user: @user, items: [item], registry: FakeRegistry.new(FakeTool)).call

    assert_equal [:error], report.questions.first.calls.map(&:status)
    refute report.passed?
  end

  test 'cross questions over two tool calls fail coverage' do
    FakeTool.tool_name = 'fixture_read'
    FakeTool.available = true
    FakeTool.data = { ok: true }
    item = TeamChat::Battery::Item.new(id: 'x', module: 'cross', question: 'fixture', checks: %w[fixture_read fixture_read fixture_read], needs: [])

    report = TeamChat::BatteryCoverage.new(user: @user, items: [item], registry: FakeRegistry.new(FakeTool)).call

    assert_equal 1, report.too_many_calls
    refute report.passed?
  end

  test 'all battery tool checks execute against the fixture database with needs and cross questions stay within two calls' do
    %w[default finance cross].each do |set|
      items = TeamChat::Battery.items(TeamChat::Battery.config_for(set))
      report = TeamChat::BatteryCoverage.new(user: @user, items: items).call

      assert report.passed?, "#{set}: #{report.markdown}"
      assert report.questions.flat_map(&:calls).all? { |call| %i[ok empty].include?(call.status) }
      assert_equal 0, report.too_many_calls
    end
  end

  test 'every metric in the catalog has a battery question that calls it' do
    asked = %w[default finance cross].flat_map { |set| TeamChat::Battery.items(TeamChat::Battery.config_for(set)) }
                                     .flat_map(&:checks).filter_map { |check| check.is_a?(Hash) && check['tool'] == 'metric' ? check.dig('args', 'name') : nil }
    missing = Metrics.catalog.map(&:key) - asked
    assert_empty missing, "Metrics without a battery question: #{missing.join(', ')}"
  end

  test 'rake coverage task writes the fixture result report' do
    Rails.application.load_tasks unless Rake::Task.task_defined?('team_chat:battery_coverage')
    task = Rake::Task['team_chat:battery_coverage']
    task.reenable
    paths = %w[default finance cross].map { |set| Rails.root.join('tmp', 'battery', "coverage-#{set}.md") }
    saved = %w[BATTERY TENANT_ID USER_EMAIL].to_h { |key| [key, ENV[key]] }

    output = capture_io do
      ENV['BATTERY'] = 'all'
      ENV['TENANT_ID'] = @tenant.id
      ENV['USER_EMAIL'] = @user.email
      task.execute
    end.first

    assert_includes output, 'cross: 10 questions, 0 errors, 0 missing needs, 0 cross questions over two calls'
    paths.each { |path| assert File.exist?(path) }
    assert_includes File.read(paths.last), '| x01 | 1 |'
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    paths&.each { |path| FileUtils.rm_f(path) }
  end
end
