# frozen_string_literal: true

require 'test_helper'

class TeamChatBatteryComparisonTest < ActiveSupport::TestCase
  Run = Struct.new(:set_name, :status, :tenant_id, :model, :revision, :questions, :results_list, keyword_init: true)

  def make_run(model, rows, set_name: 'finance-cohort-0123456789abcdef')
    rows = rows.map { |row| { 'grader' => 'fake-grader' }.merge(row) }
    Run.new(set_name: set_name, status: 'done', tenant_id: 'test', model: model, revision: 'test-rev', questions: rows.size, results_list: rows)
  end

  test 'uses paired grades and reports missing ones without treating them as failures' do
    base = make_run('qwen', [{ 'id' => '1', 'question' => 'A', 'grade' => 4 }, { 'id' => '2', 'question' => 'B', 'grade' => 3 }])
    candidate = make_run('lfm', [{ 'id' => '1', 'question' => 'A', 'grade' => 5 }, { 'id' => '2', 'question' => 'B', 'grade' => nil }])
    result = TeamChat::Battery::Comparison.new(baseline: base, candidate: candidate).call
    assert_equal [2, 1, 1, 1.0, 1], result.values_at('questions', 'paired_graded', 'unpaired', 'mean_difference', 'candidate_ungraded')
    assert_equal [1, 0, 0], result.values_at('wins', 'ties', 'losses')
  end

  test 'rejects mismatched evidence cohorts and changed question text' do
    rows = [{ 'id' => '1', 'question' => 'A', 'grade' => 5 }]
    base = make_run('qwen', rows)
    assert_raises(TeamChat::Battery::Comparison::Error) do
      TeamChat::Battery::Comparison.new(baseline: base, candidate: make_run('lfm', rows, set_name: 'finance'))
    end
    comparison = TeamChat::Battery::Comparison.new(baseline: base, candidate: make_run('lfm', [{ 'id' => '1', 'question' => 'Changed', 'grade' => 5 }]))
    assert_raises(TeamChat::Battery::Comparison::Error) { comparison.call }
  end

  test 'rejects different revisions and graders' do
    rows = [{ 'id' => '1', 'question' => 'A', 'grade' => 5 }]
    baseline = make_run('qwen', rows)
    candidate = make_run('lfm', rows)
    candidate.revision = 'different'
    assert_raises(TeamChat::Battery::Comparison::Error) { TeamChat::Battery::Comparison.new(baseline: baseline, candidate: candidate) }
    candidate.revision = baseline.revision
    candidate.results_list.first['grader'] = 'different-judge'
    comparison = TeamChat::Battery::Comparison.new(baseline: baseline, candidate: candidate)
    assert_raises(TeamChat::Battery::Comparison::Error) { comparison.call }
  end
end
