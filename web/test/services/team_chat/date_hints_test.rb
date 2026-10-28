# frozen_string_literal: true

require 'test_helper'

class TeamChatDateHintsTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 22) # a Thursday

  def hints(text) = TeamChat::DateHints.call(text, today: TODAY)

  test 'relative dates become exact dates with the period_review name' do
    assert_equal ['last month = 2026-09-01 to 2026-09-30 (period_review period: last_month)'], hints('How did last month go?')
    assert_equal ['yesterday = 2026-10-21 (period_review period: yesterday)'], hints('Sales yesterday?')
    assert_equal ['last quarter = 2026-07-01 to 2026-09-30 (period_review period: last_quarter)'], hints('How did last quarter compare?')
    assert_equal ['year to date = 2026-01-01 to 2026-10-22 (period_review period: year_to_date)'], hints('Gross sales YTD?')
    assert_equal ['the last 30 days = 2026-09-23 to 2026-10-22'], hints('best day in the last 30 days')
    assert_equal ['the last 999 days = 2024-01-28 to 2026-10-22'], hints('last 999 days')
    assert_includes hints('last 0 days').first, 'do not substitute a different range'
  end

  test 'pay weeks are not also calendar weeks, and plain questions get nothing' do
    assert_equal ['last pay week = 2026-10-15 to 2026-10-21 (period_review period: last_pay_week)'], hints('hours last pay week')
    assert_equal ['this month = 2026-10-01 to 2026-10-22 (period_review period: this_month)'], hints('expenses so far this month')
    assert_empty hints('Is sync healthy?')
  end

  test 'abbreviated last week retains the requested calendar or pay period' do
    assert_equal ['last week = 2026-10-12 to 2026-10-18 (period_review period: last_week)'], hints('hours lst week')
    assert_equal ['last pay week = 2026-10-15 to 2026-10-21 (period_review period: last_pay_week)'], hints('hours lst pay week')
  end
end
