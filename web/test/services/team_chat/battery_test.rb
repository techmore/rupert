# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatBatteryTest < ActiveSupport::TestCase
  include TeamChatHelper

  FakeGrader = Struct.new(:calls) do
    def label = 'fake-grader'

    def grade(**kwargs)
      calls << kwargs
      { score: 4, verdict: 'Right totals, missed the top product.', issues: ['No top product'], seconds: 1.5 }
    end
  end

  setup do
    @tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.tenant = @tenant
    Current.user = @user
    @previous = ENV['RUPERT_LOCAL_LLM_URL']
    ENV['RUPERT_LOCAL_LLM_URL'] = LLM_BASE
  end

  teardown do
    ENV['RUPERT_LOCAL_LLM_URL'] = @previous
    Current.reset
  end

  def items
    [TeamChat::Battery::Item.new(id: 'd1', cadence: 'daily', question: 'How did we do yesterday?', checks: [{ 'tool' => 'period_review', 'args' => { 'period' => 'yesterday' } }]),
     TeamChat::Battery::Item.new(id: 'm3', cadence: 'monthly', question: 'Sales tax last month?', checks: [{ 'tool' => 'sales_tax_report', 'args' => { 'from' => 'last_month.from', 'to' => 'last_month.to' } }])]
  end

  test 'depth and breadth use distinct complete question sets' do
    depth = TeamChat::Battery.items_for('depth')
    expected = %w[default finance cross visualization].flat_map { |name| TeamChat::Battery.items(TeamChat::Battery.config_for(name)) }
    assert_equal expected.map(&:id), depth.map(&:id)
    assert_equal depth.size, depth.map(&:id).uniq.size
    breadth = TeamChat::Battery.items_for('breadth')
    assert_equal TeamChat::QuestionBank.questions.map(&:id), breadth.map(&:id)
    assert_equal breadth.size, breadth.map(&:id).uniq.size
    assert_operator breadth.size, :>, depth.size
    assert_nil TeamChat::Battery::OfflineGrader.new.grade(question: 'test', answer: 'test', reference: '', tools_used: [])
    offline = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: TeamChat::Battery::OfflineGrader.new,
      items: depth, set: 'depth', out: nil)
    assert_equal 'depth-offline', offline.record_set_name
  end

  test 'long benchmarks remain running while results are still being saved' do
    run = TeamChat::BatteryRun.new(status: 'running', started_at: 4.hours.ago, updated_at: Time.current)
    assert_equal 'running', run.display_status
    run.updated_at = 3.hours.ago
    assert_equal 'stopped', run.display_status
  end

  test 'benchmark rows report view type and unchecked figures without claiming semantic verification' do
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: TeamChat::Battery::OfflineGrader.new, items: [], out: nil)
    result = TeamChat::Battery::Result.new(item: items.first, seconds: 1.0, tools: ['show_view'], status: 'done',
      unverified: [], proposed_tools: [], views: [{ 'kind' => 'bar_chart', 'rows' => [[1, 2]], 'unchecked' => 1 },
                                                  { 'kind' => 'html', 'unchecked' => 0 }])
    views = battery.send(:result_row, result).fetch('views')
    assert_equal({ 'kind' => 'bar_chart', 'rows' => 1, 'unmatched_figures' => 1, 'adjustable' => true }, views.first)
    assert_equal false, views.last['adjustable']
    assert_not views.first.key?('verified')
    visual = result.item.dup
    visual.module = 'visualization'
    result.item = visual
    battery.instance_variable_set(:@results, [result])
    assert_includes battery.send(:summary_text, nil), 'Side-panel views: 1/1 answers; 1 include an adjustable structured view'
    assert_includes battery.send(:summary_text, nil), 'Data, labels and scope require review'
  end

  test 'a visualization benchmark records the view produced during a real run' do
    item = TeamChat::Battery::Item.new(id: 'v01', cadence: 'daily', module: 'visualization', question: 'Plot the test values',
      checks: [], expect: 'Show a structured chart', needs: [])
    script_model({ tool: 'show_view', arguments: { title: 'Values', kind: 'bar_chart', columns: %w[Day Count], rows: [['Mon', 3]] } },
      { text: 'Here is the chart.' })
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: TeamChat::Battery::OfflineGrader.new, items: [item], set: 'visualization', out: nil)
    result = battery.run.sole
    assert_equal 'bar_chart', result.views.sole['kind']
    row = battery.record.reload.results_list.sole
    assert_equal true, row.fetch('views').sole.fetch('adjustable')
    assert_equal 1, row.fetch('views').sole.fetch('unmatched_figures')
    assert_nil row['grade']
  end

  test 'combined benchmark job uses the offline grader and rejects a hosted verifier' do
    local = TeamChat::LocalAgents::ALL.first
    TeamChat::LocalAgents.stubs(:find).with(local.handle).returns(local)
    TeamChat::Verify.stubs(:enabled_for?).with(local).returns(false)
    TeamChat::Battery.stubs(:items_for).with('breadth').returns([])
    runner = mock('offline benchmark')
    runner.expects(:already_done).returns(nil)
    runner.expects(:run)
    TeamChat::Battery.expects(:new).with(user: @user, agent: local.handle, items: [], set: 'breadth', out: nil,
      grader: instance_of(TeamChat::Battery::OfflineGrader)).returns(runner)
    TeamChat::BatteryJob.new.perform(@user.id, 'breadth', local.handle)

    TeamChat::Verify.stubs(:enabled_for?).with(local).returns(true)
    TeamChat::Battery.expects(:new).never
    TeamChat::BatteryJob.new.perform(@user.id, 'breadth', local.handle)
  end

  test 'does not grade an answer without usable reference or an authored expectation' do
    grader = FakeGrader.new([])
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: grader, items: [], out: nil)
    reply = Struct.new(:status, :body, :meta).new('done', 'An answer', {})
    missing = TeamChat::Battery::Item.new(id: 'missing', question: 'Where?', checks: [])
    unavailable = TeamChat::Battery::Item.new(id: 'bad', question: 'What?', checks: ['not_a_real_tool'])
    assert_nil battery.send(:grade_for, missing, reply)
    assert_nil battery.send(:grade_for, unavailable, reply)
    assert_empty grader.calls
    missing.expect = 'A correct answer explains that the information is unavailable.'
    assert_equal 4, battery.send(:grade_for, missing, reply)[:score]
  end

  test 'a question exceeding its deadline is cancelled and scored as a failure' do
    item = TeamChat::Battery::Item.new(id: 'slow', cadence: 'daily', question: 'A slow question?', checks: [])
    grader = FakeGrader.new([])
    TeamChat::Agent.any_instance.stubs(:run).with do
      sleep 0.2
      true
    end.returns(nil)
    original = TeamChat::Battery::QUESTION_TIMEOUT
    TeamChat::Battery.send(:remove_const, :QUESTION_TIMEOUT)
    TeamChat::Battery.const_set(:QUESTION_TIMEOUT, 0.02)
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: grader, items: [item], out: nil)
    result = battery.run.first
    assert_equal 'failed', result.status
    assert_equal 1, result.grade[:score]
    assert_match(/120 seconds/, result.grade[:verdict])
    assert_empty grader.calls
  ensure
    TeamChat::Battery.send(:remove_const, :QUESTION_TIMEOUT)
    TeamChat::Battery.const_set(:QUESTION_TIMEOUT, original)
  end

  test 'a timed out question retains the proposed tool after cancellation' do
    item = TeamChat::Battery::Item.new(id: 'slow-action', cadence: 'general', question: 'Make a task', checks: [])
    TeamChat::Agent.any_instance.stubs(:run).with do
      reply = TeamChat::Message.where(author_kind: 'assistant', status: 'pending').last
      TeamChat::Actions.propose!(reply, tool: 'create_task', arguments: { 'title' => 'Recount' }, proposed_for: @user)
      sleep 2
      true
    end.returns(nil)
    original = TeamChat::Battery::QUESTION_TIMEOUT
    TeamChat::Battery.send(:remove_const, :QUESTION_TIMEOUT)
    TeamChat::Battery.const_set(:QUESTION_TIMEOUT, 1)
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: FakeGrader.new([]), items: [item], out: nil)
    assert_no_difference -> { Projects::Task.count } do
      battery.run
    end
    assert_equal ['create_task'], battery.record.reload.results_list.first['proposed_tools']
    assert_equal 'dismissed', TeamChat::Message.where(author_kind: 'assistant').last.actions_list.first['status']
  ensure
    TeamChat::Battery.send(:remove_const, :QUESTION_TIMEOUT)
    TeamChat::Battery.const_set(:QUESTION_TIMEOUT, original)
  end

  test 'model scores exclude runs with ungraded questions while preserving the run' do
    complete = TeamChat::BatteryRun.create!(tenant_id: @tenant.id, run_key: 'complete', set_name: 'finance', model: 'complete-model',
      status: 'done', questions: 2, results: [{ 'grade' => 4 }, { 'grade' => 5 }], avg_grade: 4.5, started_at: Time.current)
    partial = TeamChat::BatteryRun.create!(tenant_id: @tenant.id, run_key: 'ungraded', set_name: 'finance', model: 'partial-model',
      status: 'done', questions: 2, results: [{ 'grade' => 5 }, { 'grade' => nil }], avg_grade: 5, started_at: Time.current)

    assert complete.fully_graded?
    refute partial.fully_graded?
    assert_equal 4.5, TeamChat::BatteryRun.latest_scores.dig('complete-model', 'finance')
    assert_nil TeamChat::BatteryRun.latest_scores['partial-model']
    assert TeamChat::BatteryRun.exists?(partial.id)
  end

  test 'missing declared reference fields prevent grading' do
    grader = FakeGrader.new([])
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: grader, items: [], out: nil)
    reply = Struct.new(:status, :body, :meta).new('done', 'An answer', {})
    item = TeamChat::Battery::Item.new(id: 'missing', question: 'What?', checks: ['sync_health'], needs: ['sync_health:missing_field'])

    assert_nil battery.send(:grade_for, item, reply)
    assert_empty grader.calls
  end

  test 'navigation references use the asking user and contain a real page' do
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: FakeGrader.new([]), items: [], out: nil)
    item = TeamChat::Battery::Item.new(id: 'where', question: 'where are timesheets?',
      checks: [{ 'tool' => 'where_is', 'args' => { 'query' => 'timesheets' } }])
    assert_includes battery.send(:reference_for, item), '/people/timesheets'
  end

  test 'two models using one cohort save paired comparison results' do
    item = TeamChat::Battery::Item.new(id: 'paired', cadence: 'general', question: 'Where?', checks: [],
      expect: 'Direct the user to the appropriate page.', needs: [])
    cohort = TeamChat::Battery::Cohort.capture(user: @user, items: [item]) { '' }
    script_model({ text: 'Open the page.' }, { text: 'Open the page.' })
    grader = FakeGrader.new([])
    first = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: grader, items: [item], out: nil, cohort: cohort)
    second = TeamChat::Battery.new(user: @user, agent: 'gemma', grader: grader, items: [item], out: nil, cohort: cohort)
    first.run
    second.run

    assert_match(/-cohort-#{cohort.id}\z/, first.record.set_name)
    comparison = TeamChat::Battery::Comparison.new(baseline: first.record, candidate: second.record).call
    assert_equal [1, 0.0], comparison.values_at('paired_graded', 'mean_difference')
    assert_equal 2, TeamChat::BatteryRun.where(id: [first.record.id, second.record.id]).count
  end

  test 'asks each question to the bot on its own in its test room, times it, grades it and posts a pinned summary' do
    requests = script_model({ tool: 'period_review', arguments: { period: 'yesterday' } }, { text: 'Yesterday: 2 orders, $100.' }, { text: 'No tax data.' })
    grader = FakeGrader.new([])
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: grader, items: items, out: nil)
    results = battery.run

    room = TeamChat::Room.find_by!(slug: "test-qwen-#{@user.id}")
    assert_equal ['done', 'done'], results.map(&:status)
    assert_equal [['period_review'], []], results.map(&:tools)
    replies = room.messages.where(author_kind: 'assistant').order(:id)
    assert_equal %w[qwen qwen], replies.map { |reply| reply.meta['agent'] }
    assert_equal 'qwen3.5-4b', requests.first['model']
    # Each question stands alone: the second request does not carry the first question.
    assert_not_includes requests.last['messages'].map { |message| message['content'].to_s }.join, 'How did we do yesterday?'

    assert_equal 2, grader.calls.size
    assert_match(/period_review\(\{"period":"yesterday"\}\)/, grader.calls.first[:reference])
    assert_match(/"from":"#{Date.current.prev_month.beginning_of_month.iso8601}"/, grader.calls.last[:reference])
    # Bodies are encrypted at rest (#421), so the notices are picked out in Ruby.
    grades = room.messages.where(author_kind: 'system').order(:id).select { |notice| notice.body.start_with?('Grade ') }
    assert_equal 2, grades.size
    assert_match(/Grade 4\/5 for Qwen .*Right totals.*\n- No top product\n— graded by fake-grader/m, grades.first.body)

    summary = room.messages.pinned.first
    assert_match(/answered 2\/2/, summary.body)
    assert_match(%r{Average grade 4.0/5}, summary.body)
    assert_match(/By cadence: daily 4.0 · monthly 4.0/, summary.body)
    assert_match(/Number check flagged figures in 0 of 2 replies; an unflagged reply is not necessarily verified/, summary.body)
    report = battery.report_markdown
    assert_match(/\| 1 \| daily \| How did we do yesterday\? \| [\d.]+ s \| period_review \| — \| 4 \|/, report)
  end

  test 'each run is saved with its per-question results, and the same model, set and build counts as already done' do
    script_model({ tool: 'period_review', arguments: { period: 'yesterday' } }, { text: 'Yesterday: 2 orders, $100.' }, { text: 'No tax data.' })
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: FakeGrader.new([]), items: items, out: nil)
    battery.run

    run = TeamChat::BatteryRun.find_by!(run_key: battery.run_id)
    assert_equal ['done', 'default', 'qwen', 'qwen3.5-4b', 2, 2], [run.status, run.set_name, run.agent, run.model, run.questions, run.answered]
    assert_in_delta 4.0, run.avg_grade.to_f
    assert_equal({ 'daily' => 4.0, 'monthly' => 4.0 }, run.cadence_scores)
    assert_equal 0, run.flagged
    assert_equal %w[d1 m3], run.results_list.pluck('id')
    assert_empty run.results_list.first['unverified']
    assert_equal run, TeamChat::Battery.new(user: @user, agent: 'qwen', grader: FakeGrader.new([]), items: items, out: nil).already_done
    assert_nil TeamChat::Battery.new(user: @user, agent: 'qwen', only: ['d1'], grader: FakeGrader.new([]), items: items, out: nil).already_done
  end

  test 'runs from before saving are rebuilt from #liquid-testing' do
    room = TeamChat::Room.create!(name: 'liquid-testing', slug: 'liquid-testing', kind: 'channel', assistant_mode: 'off', created_by: @user)
    room.messages.create!(author_kind: 'system', body: '🧪 Test run old-1 (finance questions): 1 questions', meta: { 'battery' => 'old-1' })
    question = room.messages.create!(user: @user, body: '@qwen How much tax?', meta: { 'battery' => 'old-1', 'item' => 'f15', 'cadence' => 'tax' })
    reply = room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Per source…',
      meta: { 'battery' => 'old-1', 'trigger_id' => question.id, 'agent' => 'qwen', 'model' => 'qwen3.5-4b', 'duration_ms' => 9000, 'tools' => ['sales_tax_report'] })
    room.messages.create!(author_kind: 'system', body: "Grade 5/5 for Qwen (9.0 s, sales_tax_report): Exact per source.\n— graded", meta: { 'battery' => 'old-1', 'grade' => 5, 'graded_message' => reply.id })
    room.messages.create!(author_kind: 'system', body: '📋 Test run old-1 done', meta: { 'battery' => 'old-1' })

    assert_equal 1, TeamChat::BatteryRun.backfill!
    assert_equal 0, TeamChat::BatteryRun.backfill!
    run = TeamChat::BatteryRun.find_by!(run_key: 'old-1')
    assert_equal ['done', 'finance', 'qwen', 5.0, 9.0], [run.status, run.set_name, run.agent, run.avg_grade.to_f, run.avg_seconds]
    assert_equal 'Exact per source.', run.results_list.first['verdict']
    assert_equal 'How much tax?', run.results_list.first['question']
  end

  test 'a proposal made during a test run is dismissed, so nothing changes' do
    script_model({ tool: 'create_task', arguments: { title: 'Recount' } }, { text: 'Proposed.' })
    item = TeamChat::Battery::Item.new(id: 'x', cadence: 'general', question: 'Make a task', checks: [])
    battery = TeamChat::Battery.new(user: @user, agent: 'qwen', grader: FakeGrader.new([]), items: [item], out: nil)
    assert_no_difference -> { Projects::Task.count } do
      battery.run
    end
    reply = TeamChat::Message.where(author_kind: 'assistant').last
    assert_equal 'dismissed', reply.actions_list.first['status']
    assert_equal ['create_task'], battery.record.reload.results_list.first['proposed_tools']
  end

  test 'every bot gets its own test room, created up front' do
    slugs = TeamChat::Battery.ensure_rooms!(@user).map(&:slug)
    assert_includes slugs, "test-rupert-#{@user.id}"
    assert_includes slugs, "test-qwen-#{@user.id}"
    assert_includes slugs, "test-gemma-e2b-#{@user.id}"
    assert_equal slugs.size, TeamChat::Room.where(slug: slugs).count
    assert TeamChat::Room.where(slug: slugs).all? { |room| room.direct? && room.created_by_id == @user.id }
    other = User.create!(tenant: @tenant, email: 'battery-peer@example.com', role: 'admin', password: 'password123')
    assert TeamChat::Room.where(slug: slugs).none? { |room| room.visible_to?(other) }
    assert TeamChat::Room.find_by(slug: "test-qwen-#{@user.id}").visible_to?(@user)
    assert_equal "rupert-#{@user.id}", TeamChat::Room.direct_for(@user).slug
  end

  test 'trial models are only for the battery, and an unknown bot is refused' do
    assert_equal 'gemma-4-e2b', TeamChat::LocalAgents.trial('gemma-e2b').model
    assert_nil TeamChat::LocalAgents.find('gemma-e2b')
    assert_raises(ArgumentError) { TeamChat::Battery.new(user: @user, agent: 'nobody', grader: FakeGrader.new([]), items: items, out: nil) }
    assert_equal 21, TeamChat::Battery.items.size
    finance = TeamChat::Battery.items(TeamChat::Battery.config_for('finance'))
    assert_equal 35, finance.size, 'f22-f24 ask about the store registers; f25-f35 call the metric tool'
    assert_match(/no cost of goods/, finance.find { |item| item.id == 'f20' }.expect)
    assert_equal %w[sales comparison money_out tax books honesty daily], finance.map(&:cadence).uniq
    assert_raises(ArgumentError) { TeamChat::Battery.config_for('../etc/passwd') }
    assert_raises(ArgumentError) { TeamChat::Battery.config_for('nope') }
    assert_equal TeamChat::Battery::CONFIG, TeamChat::Battery.config_for(nil)
  end

  test 'answers over two minutes are logged and listed on Model scores' do
    room = TeamChat::Room.ensure_defaults!(@user)
    asked = room.messages.create!(user: @user, body: '@liquid slow one')
    room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Late answer',
      meta: { 'asked_by' => @user.id, 'trigger_id' => asked.id, 'agent' => 'liquid', 'model' => 'lfm2.5-8b-a1b', 'duration_ms' => 150_000 })
    room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Quick', meta: { 'agent' => 'liquid', 'model' => 'lfm2.5-8b-a1b', 'duration_ms' => 20_000 })
    slow = TeamChat::ModelScores.slow
    assert_equal [[150, '@liquid slow one']], slow.map { |row| [row.seconds, row.question] }
    row = TeamChat::ModelScores.call.find { |score| score.agent == 'liquid' }
    assert_equal [1, 2, 50], [row.slow, row.answered, row.slow_percent]
  end
end
