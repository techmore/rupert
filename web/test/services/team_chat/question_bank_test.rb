# frozen_string_literal: true

require 'test_helper'

class TeamChatQuestionBankTest < ActiveSupport::TestCase
  Q = TeamChat::QuestionBank::Question

  def q(text, tools, answerable = 'yes', mod = 'sell')
    Q.new(id: "t-#{text.hash.abs}", module: mod, question: text, tools: tools, answerable: answerable)
  end

  test 'a question is a hit when its keywords offer the tools it needs, a miss when not, unguided when no topic matches' do
    hit = TeamChat::QuestionBank.check(q('How much sales tax did we collect last month?', ['sales_tax_report']))
    assert_equal ['hit', []], [hit.outcome, hit.missing]
    miss = TeamChat::QuestionBank.check(q('How much sales tax did we collect last month?', ['list_alerts']))
    assert_equal ['miss', ['list_alerts']], [miss.outcome, miss.missing]
    assert_equal 'fallback', TeamChat::QuestionBank.check(q('hello there friend', ['list_tasks'])).outcome
    assert_equal 'lookup', TeamChat::QuestionBank.check(q('where do I approve timesheets', ['where_is'])).outcome
  end

  test 'scores: routing over answerable questions, coverage over all, plus an overall row' do
    list = [q('sales tax last month?', ['sales_tax_report']), q('sales tax last month??', ['list_alerts']),
            q('hello there', ['list_tasks']), q('our campaign results?', [], 'no', 'marketing'),
            q('discounts used last week?', ['sales_summary'], 'partial', 'marketing')].map { |row| TeamChat::QuestionBank.check(row) }
    marketing, sell, all = TeamChat::QuestionBank.scores(list)
    assert_equal ['sell', 3, 50, 100, 1, 1, 1], [sell.module, sell.questions, sell.routing, sell.coverage, sell.hits, sell.fallbacks, sell.misses]
    assert_equal ['marketing', 25, 2], [marketing.module, marketing.coverage, marketing.gaps]
    assert_equal ['all', 5], [all.module, all.questions]
  end

  test 'every question in the bank is well formed and names tools that exist' do
    known = Mcp::Registry.tools.map(&:tool_name) + TeamChat::Toolbox::LOOKUPS
    questions = TeamChat::QuestionBank.questions
    skip 'no question bank files yet' if questions.empty?
    assert_equal questions.size, questions.map(&:id).uniq.size, 'ids are unique'
    questions.each do |question|
      assert_includes %w[yes partial no], question.answerable, question.id
      assert_empty question.tools - known, "#{question.id} names an unknown tool"
      assert question.gap.present?, "#{question.id}: partial/no needs a gap note" if question.answerable != 'yes'
    end
    report = TeamChat::QuestionBank.report(limit: 2)
    assert_match(/\Amodule\s+questions routing coverage/, report)
  end

  test 'battery_items: a fixed sample per area, one unanswerable question graded for honesty' do
    items = TeamChat::QuestionBank.battery_items(per: 2)
    skip 'no question bank files yet' if items.empty?
    assert_equal items.map(&:id), TeamChat::QuestionBank.battery_items(per: 2).map(&:id), 'same seed, same sample'
    areas = TeamChat::QuestionBank.questions.map(&:module).uniq
    assert_equal areas.size * 3, items.size
    honesty = items.select { |item| item.cadence == 'honesty' }
    assert_equal areas.size, honesty.size
    assert(honesty.all? { |item| item.expect.include?('has no data') })
    assert(items.flat_map(&:checks).all? do |check|
      name = check.is_a?(Hash) ? check['tool'] : check
      %w[where_is how_do_i].include?(name) || Mcp::Registry.find(name)&.read_only
    end,
      'checks are read-only MCP tools or navigation lookups')
  end

  test 'authored task expectations are retained in the graded bank' do
    items = TeamChat::QuestionBank.questions.index_by(&:id)
    %w[daily-161 team-192 work-074].each do |id|
      item = TeamChat::QuestionBank.battery_item(items.fetch(id))
      assert_includes item.expect, 'approved action'
      assert_empty item.checks
    end
  end

  test 'business snapshot uses the current pulse rather than a stale unavailable label' do
    question = TeamChat::QuestionBank.questions.find { |row| row.id == 'bookkeeping-012' }
    assert_equal 'partial', question.answerable
    item = TeamChat::QuestionBank.battery_item(question)
    assert_equal ['business_pulse'], item.checks
    assert_includes item.expect, 'Do not infer profit or cash balances'
  end

  test 'authored financial references use the named metric and store source' do
    items = TeamChat::QuestionBank.questions.index_by(&:id)
    month = TeamChat::QuestionBank.battery_item(items.fetch('bookkeeping-187'))
    quarter = TeamChat::QuestionBank.battery_item(items.fetch('cross-160'))
    store = TeamChat::QuestionBank.battery_item(items.fetch('daily-042'))
    assert_equal({ 'name' => 'refund_rate', 'period' => 'this_month' }, month.checks.first.fetch('args'))
    assert_equal 'this_quarter', quarter.checks.first.fetch('args').fetch('period')
    assert_equal 'daily_close', store.checks.first.fetch('tool')
    assert_includes store.needs, 'daily_close:note'
  end

  test 'navigation questions supply their text to a lookup instead of an empty reference' do
    item = TeamChat::QuestionBank.battery_item(q('where do I approve timesheets', ['where_is']))
    assert_equal [{ 'tool' => 'where_is', 'args' => { 'query' => item.question } }], item.checks
  end

  test 'unscoped data defaults do not become a misleading grading reference' do
    quarter = TeamChat::QuestionBank.battery_item(q('sales tax by county for last quarter', ['sales_tax_report']))
    assert_empty quarter.checks
    assert_nil quarter.expect

    partial = TeamChat::QuestionBank.battery_item(q('where and how much sold last week', %w[where_is sales_summary], 'partial'))
    assert_empty partial.checks
    assert_nil partial.expect
  end
end
