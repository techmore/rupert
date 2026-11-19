# frozen_string_literal: true

require 'test_helper'

class TeamChatScorecardTest < ActiveSupport::TestCase
  setup { Current.tenant = tenants(:default_tenant) }
  teardown { Current.reset }

  def run!(model, set, rows, started: 1.hour.ago, status: 'done')
    TeamChat::BatteryRun.create!(run_key: SecureRandom.hex(4), set_name: set, agent: 'qwen', model: model, engine: 'local_gateway', status: status,
      questions: rows.size, answered: rows.size, results: rows, avg_seconds: 10.0, started_at: started)
  end

  def row(id, grade, seconds: 10.0, tools: %w[metric], unverified: [], status: 'done', cadence: 'x')
    { 'id' => id, 'cadence' => cadence, 'grade' => grade, 'seconds' => seconds, 'tools' => tools, 'unverified' => unverified, 'status' => status }
  end

  test 'maps each axis to 0-9 and leaves unmeasured axes blank' do
    scores = TeamChat::Scorecard.scores([row('d2', 5, seconds: 2.0), row('d3', 1, seconds: 2.0, tools: [], unverified: ['$5']), row('d5', nil, seconds: 0, status: 'failed')])
    assert_equal 5, scores['quality'], 'grades 5 and 1 average 3 of 5, which is 4.5 of 9'
    assert_equal 9, scores['speed'], 'answers of 2 seconds or less score the full 9'
    assert_equal 6, scores['reliability'], '2 of 3 answered'
    assert_equal 5, scores['tool_use'], 'one of the two answers used a tool'
    assert_equal 5, scores['grounding']
    assert_nil scores['first_token'], 'no first-token time recorded, so it is blank rather than zero'
    assert_equal 0.0, TeamChat::Scorecard.speed_fraction(120), 'at the two-minute limit an answer scores 0'
    assert_in_delta 0.5, TeamChat::Scorecard.speed_fraction(2 * Math.sqrt(60)), 1e-9, 'halfway in log time between 2 and 120 seconds is half marks'
    assert_equal 1.0, TeamChat::Scorecard.speed_fraction(2)
    assert_equal 1.0, TeamChat::Scorecard.speed_fraction(0.5)
    assert_equal 4, (TeamChat::Scorecard.speed_fraction(20) * 9).round, 'a 20 second answer is no longer a full score'
    assert_equal 3, TeamChat::Scorecard.scores([row('a', 3, seconds: 20.0), row('b', 3, seconds: 70.0), row('c', 3, seconds: 900.0)])['speed'], 'a 900 second answer is ignored; 20 s and 70 s score 0.44 and 0.13 on the log scale, mean 0.28, which is 2.6 of 9'
    assert_equal 0, TeamChat::Scorecard.scores([row('d2', 1)])['quality']
  end

  test 'first token scores the median time to first token on a log scale and stays blank without one' do
    first = ->(*seconds) { TeamChat::Scorecard.scores(seconds.map { |value| row('a', 3).merge('ttft_seconds' => value) })['first_token'] }
    assert_equal 9, first.call(0.4), 'at or under 1 second is full marks'
    assert_equal 0, first.call(20.0)
    assert_equal 0, first.call(90.0), 'slower than 20 seconds is 0, not negative'
    assert_equal 5, first.call(4.0), 'near the log-scale middle of 1 and 20 seconds'
    assert_equal 9, first.call(0.5, 0.8, 15.0), 'the median, not the mean, so one slow outlier does not count'
    assert_nil TeamChat::Scorecard.scores([row('a', 3).merge('ttft_seconds' => nil), row('b', 3).merge('ttft_seconds' => 0)])['first_token']
    assert_includes TeamChat::Scorecard::SCALE, 'first_token='
  end

  test 'timing reports the median and slow end of first-token times, ignoring answers without one' do
    run!('qwen3.5-4b', 'finance', [row('a', 3).merge('ttft_seconds' => 1.0), row('b', 3).merge('ttft_seconds' => 2.0),
                                    row('c', 3).merge('ttft_seconds' => 3.0), row('d', 3)])
    run!('gemma-4-e4b', 'finance', [row('a', 3)])
    cards = TeamChat::Scorecard.call.index_by(&:model)

    assert_equal [2.0, 3.0], [cards['qwen3.5-4b'].timing.ttft_median, cards['qwen3.5-4b'].timing.ttft_p95]
    assert_nil cards['gemma-4-e4b'].timing.ttft_median
    assert_nil cards['gemma-4-e4b'].overall['first_token']
  end

  test 'builds a card per model with module scores and the change since the previous run' do
    run!('qwen3.5-4b', 'finance', [row('d2', 3), row('d3', 3), row('f15', 3)], started: 2.days.ago)
    run!('qwen3.5-4b', 'finance', [row('d2', 5), row('d3', 5), row('f15', 4)])
    run!('lfm3-1.7b', 'finance', [row('d2', 2, seconds: 60.0), row('d3', 2, seconds: 60.0), row('f15', 2, seconds: 60.0)])
    cards = TeamChat::Scorecard.call

    assert_equal %w[qwen3.5-4b lfm3-1.7b], cards.map(&:model), 'best quality first'
    qwen = cards.first
    assert_equal 8, qwen.overall['quality']
    assert_equal 3, qwen.change['quality'], 'up from 3/5 (4.5 of 9, rounds to 5) to 4.67/5 (8.25 of 9, rounds to 8)'
    assert_equal({}, cards.last.change, 'a model with one run has no change yet')
    assert qwen.modules.key?('sell')
    assert cards.last.overall['speed'] < qwen.overall['speed']
  end

  test 'reports real timing behind the speed score and can sort by any axis' do
    run!('qwen3.5-4b', 'finance', [row('d2', 3, seconds: 10.0), row('d3', 3, seconds: 20.0), row('f15', 3, seconds: 130.0)])
    run!('lfm3-1.7b', 'finance', [row('d2', 5, seconds: 40.0), row('d3', 5, seconds: 50.0), row('f15', 5, seconds: 60.0)])
    qwen = TeamChat::Scorecard.call.find { |card| card.model == 'qwen3.5-4b' }
    assert_equal [20.0, 20.0, 0, 1, 2], [qwen.timing.median, qwen.timing.slowest, qwen.timing.slow, qwen.timing.ignored, qwen.timing.answered],
      'the 130 second answer is ignored; 20 seconds is not over 20'
    assert_equal %w[lfm3-1.7b qwen3.5-4b], TeamChat::Scorecard.call(sort: 'quality').map(&:model)
    assert_equal %w[qwen3.5-4b lfm3-1.7b], TeamChat::Scorecard.call(sort: 'speed').map(&:model), 'Qwen has the faster median here'
  end

  test 'partial runs are left out, and a model that only failed shows with reliability 0 and no quality' do
    run!('gemma-4-e4b', 'default (part)', [row('d2', 5)])
    run!('gemma-4-e4b', 'default', [row('d2', nil, status: 'failed', seconds: 0)])
    card = TeamChat::Scorecard.call.sole
    assert_equal 0, card.overall['reliability']
    assert_nil card.overall['quality'], 'nothing graded is blank, not zero'
    assert_nil card.overall['speed']
  end
end
