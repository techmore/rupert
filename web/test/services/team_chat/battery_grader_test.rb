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
end
