# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

class TeamChatBatteryGraderTest < ActiveSupport::TestCase
  include TeamChatHelper

  test 'the grader receives the whole long answer and refuses an oversized one' do
    requests = script_model({ text: '{"score":4,"verdict":"checked","issues":[]}' })
    grader = TeamChat::Battery::Grader.new(config: team_chat_config)
    answer = ('a' * 4_100) + ' end-of-answer'

    assert_equal 4, grader.grade(question: 'What happened?', answer: answer, reference: 'test evidence', tools_used: [])[:score]
    assert_includes requests.first['messages'].last['content'], 'end-of-answer'
    assert_raises(TeamChat::Battery::Grader::Error) do
      grader.grade(question: 'What happened?', answer: 'a' * 12_001, reference: 'test evidence', tools_used: [])
    end
    assert_equal 1, requests.size
  end

  test 'a lucky ungrounded status claim cannot receive a high grade' do
    script_model({ text: '{"score":4,"verdict":"matches","issues":[]}' })
    grader = TeamChat::Battery::Grader.new(config: team_chat_config)
    grade = grader.grade(question: 'Are any reconciliation follow-ups open?',
      answer: 'There are no reconciliation follow-ups open.', reference: 'The queue is empty.', tools_used: [])

    assert_equal 2, grade[:score]
    assert_includes grade[:verdict], 'without a data lookup'
  end

  test 'cautious refusals and checked statuses are not capped as ungrounded claims' do
    script_model({ text: '{"score":4,"verdict":"checked","issues":[]}' }, { text: '{"score":4,"verdict":"checked","issues":[]}' },
      { text: '{"score":4,"verdict":"checked","issues":[]}' })
    grader = TeamChat::Battery::Grader.new(config: team_chat_config)
    question = 'Are any reconciliation follow-ups open?'
    assert_equal 4, grader.grade(question: question, answer: 'I could not check those records.', reference: 'The queue is empty.', tools_used: [])[:score]
    assert_equal 4, grader.grade(question: question, answer: 'There are no follow-ups open.', reference: 'The queue is empty.', tools_used: ['order_queues'])[:score]
    assert_equal 4, grader.grade(question: question, answer: 'I cannot confirm whether there are no follow-ups open.', reference: 'The queue is empty.', tools_used: [])[:score]
  end
end
