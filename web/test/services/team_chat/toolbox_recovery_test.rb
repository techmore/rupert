# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/team_chat_helper'

# What a small model sees when a tool call goes wrong: enough to fix the call, and a clear sign when a result was cut.
class TeamChatToolboxRecoveryTest < ActiveSupport::TestCase
  include TeamChatHelper

  setup do
    Current.tenant = tenants(:default_tenant)
    @user = users(:regular_user)
    Current.user = @user
    @room = TeamChat::Room.direct_for(@user)
    @room.update!(assistant_mode: 'mentions')
    @reply = TeamChat::Post.call(room: @room, user: @user, body: '@rupert show gross sales').reply
    @toolbox = TeamChat::Toolbox.new(user: @user, room: @room, reply: @reply)
  end
  teardown { Current.reset }

  test 'an unknown tool name suggests the closest real tool and lists the rest' do
    text = @toolbox.call('metrci', {})
    assert_match(/No tool named metrci\. Did you mean metric\?/, text)
    assert_match(/Use one of: .*metric/, text)
  end

  test 'a wrong name with no close match still lists the tools without a guess' do
    text = @toolbox.call('zzzzzzzzzz', {})
    assert_no_match(/Did you mean/, text)
    assert_match(/Use one of:/, text)
  end

  test 'invalid arguments name the tool, every problem and the valid arguments' do
    text = @toolbox.call('metric', { 'bogus' => 1, 'nonsense' => 2 })
    assert_match(/\AInvalid arguments for metric:/, text)
    assert_match(/Valid arguments: .*\./, text)
    assert_match(/Fix the call and try again\./, text)
  end

  test 'a result over the limit ends on a whole line and says how much was left out' do
    lines = Array.new(400) { |index| "row #{index}: #{'x' * 30}" }.join("\n")
    cut = @toolbox.send(:cut_result, lines)
    assert_operator cut.length, :<=, TeamChat::Toolbox::MAX_RESULT_CHARS
    assert_match(/\[Output cut: \d+ of #{lines.length} characters are not shown, so this list is incomplete/, cut)
    body = cut.split("\n[Output cut").first
    assert_match(/\Arow 0:/, body)
    assert_match(/row \d+: x{30}\z/, body, 'the last kept row is whole, never cut mid-row')
  end

  test 'a short result is returned untouched' do
    assert_equal 'short', @toolbox.send(:cut_result, 'short')
  end
end
