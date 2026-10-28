# frozen_string_literal: true

require 'test_helper'

class AskRupertReplyFormatTest < ActiveSupport::TestCase
  test 'removes reasoning blocks and stray closing markers from visible answers' do
    assert_equal 'Ready.', AskRupert::ReplyFormat.tidy('<think>private reasoning</think>Ready.')
    assert_equal 'Ready.', AskRupert::ReplyFormat.tidy('</think>Ready.')
    assert_equal 'Before', AskRupert::ReplyFormat.tidy('Before <think>unfinished reasoning')
  end
end
