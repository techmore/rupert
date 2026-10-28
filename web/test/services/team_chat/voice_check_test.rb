# frozen_string_literal: true

require 'test_helper'

class TeamChatVoiceCheckTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 28)

  def reason(text) = TeamChat::VoiceCheck.review_reason(text, today: TODAY)

  test 'a transcript with no date, or a sensible date, is posted as it is' do
    assert_nil reason('How were sales yesterday?')
    assert_nil reason('Total gross sales from September 1st, 2026 to September 30th, 2026')
    assert_nil reason('Compare the 1st of August 2026 with the 1st of September 2026')
    assert_nil reason('Sales for last year, 2025')
    assert_nil reason('We got 226 orders and 3 refunds')
  end

  test 'a year far from today is flagged for a check' do
    assert_match(/heard the year 2006/, reason('On September 20th, 2006, how many orders did we get?'))
    assert_match(/heard the year 2016/, reason('What did the registers take on September 22nd, 2016?'))
    assert_match(/heard the year 2031/, reason('Sales for 2031'))
  end

  test 'a year too short to be a year after a month and day is flagged' do
    assert_match(/heard “226” where a year should be/, reason('What were total gross sales from September 1st, 226 to September 30th, 226?'))
    assert_match(/heard “2”/, reason('Which product sold the most between August 1st, 2 and ID 6?'))
  end

  test 'a month and day followed by a count is not mistaken for a broken year' do
    assert_nil reason('On September 3rd, 12 orders came in')
    assert_nil reason('Is September 5th 30 percent up')
  end
end
