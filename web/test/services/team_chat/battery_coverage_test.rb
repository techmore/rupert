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

  test 'top products reference keeps currencies separate' do
    date = Date.current.beginning_of_week - 1.day
    %w[USD CAD].each_with_index do |currency, index|
      order = Core::Order.create!(source: 'shopify', source_order_id: "benchmark-currency-#{currency}",
        occurred_at: date.in_time_zone.noon, gross_cents: (index + 1) * 100, tax_cents: 0, currency: currency)
      order.mark_paid!
      order.order_lines.create!(name: 'Tea', quantity: 1, unit_cents: (index + 1) * 100, line_cents: (index + 1) * 100)
    end
    item = TeamChat::Battery.items.find { |question| question.id == 'w4' }
    report = TeamChat::BatteryCoverage.new(user: @user, items: [item]).call
    assert report.passed?, report.markdown
    rows = report.questions.first.calls.first.data[:values]
    assert_equal %w[CAD USD], rows.map { |row| row[:currency] }.sort
    assert_equal [100, 200], rows.map { |row| row[:products].first[:revenue_cents] }.sort
  end

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

  test 'queue questions require their named queue instead of an unrelated count' do
    coverage = TeamChat::BatteryCoverage.new(user: @user, items: [])
    path = 'queues[name=Purchase orders awaiting delivery].count'
    refute coverage.need_present?({ queues: [{ name: 'Other queue', count: 0 }] }, path)
    assert coverage.need_present?({ queues: [{ name: 'Purchase orders awaiting delivery', count: 0 }] }, path)
  end

  test 'a selected compliance reference contains only its named row' do
    coverage = TeamChat::BatteryCoverage.new(user: @user, items: [])
    data = { items: [{ title: 'Other', status: 'ok' }, { title: 'Target', status: 'watch', count: 0 }] }
    check = { 'tool' => 'compliance_check', 'select_title' => 'Target' }
    assert_equal({ items: [{ title: 'Target', status: 'watch', count: 0 }] }, coverage.reference_data(data, check))
    assert_equal({ items: [] }, coverage.reference_data(data, check.merge('select_title' => 'Missing')))
    refute coverage.need_present?(coverage.reference_data(data, check.merge('select_title' => 'Missing')), 'items[title=Missing].status')
  end

  test 'close references require exactly one lock row in the selected area' do
    coverage = TeamChat::BatteryCoverage.new(user: @user, items: [])
    check = { 'tool' => 'compliance_check', 'select_area' => 'Month close', 'required_title_suffix' => ': Lock the month' }
    other = { area: 'Month close', title: 'September 2026: Save report', status: 'watch', detail: 'Open' }
    lock = { area: 'Month close', title: 'September 2026: Lock the month', status: 'ok', detail: 'Locked' }
    unrelated = { area: 'Quarter close', title: 'Q3 2026: Lock the quarter', status: 'ok', detail: 'Locked' }
    missing = coverage.reference_data({ items: [other, unrelated] }, check)
    refute coverage.need_present?(missing, 'required_row.detail')
    data = coverage.reference_data({ items: [other, lock, unrelated] }, check)
    assert coverage.need_present?(data, 'required_row.detail')
    assert_equal [other, lock], data[:items]
    duplicate = coverage.reference_data({ items: [other, lock, lock] }, check)
    refute coverage.need_present?(duplicate, 'required_row.detail')
  end

  test 'multiple selected compliance rows require each named item' do
    coverage = TeamChat::BatteryCoverage.new(user: @user, items: [])
    check = { 'tool' => 'compliance_check', 'select_titles' => ['Review', 'Approval'] }
    review = { title: 'Review', status: 'ok', count: 0 }
    approval = { title: 'Approval', status: 'watch', count: 2 }
    unrelated = { title: 'Other', status: 'ok', count: 8 }
    missing = coverage.reference_data({ items: [review, unrelated] }, check)
    assert coverage.need_present?(missing, 'items[title=Review].count')
    refute coverage.need_present?(missing, 'items[title=Approval].count')
    selected = coverage.reference_data({ items: [review, unrelated, approval] }, check)
    assert_equal [review, approval], selected[:items]
    assert coverage.need_present?(selected, 'items[title=Approval].count')
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

    count = TeamChat::Battery.items(TeamChat::Battery.config_for('cross')).size
    assert_includes output, "cross: #{count} questions, 0 errors, 0 missing needs, 0 cross questions over two calls"
    paths.each { |path| assert File.exist?(path) }
    assert_includes File.read(paths.last), '| x01 | 1 |'
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    paths&.each { |path| FileUtils.rm_f(path) }
  end
end
