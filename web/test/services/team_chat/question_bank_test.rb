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
end
