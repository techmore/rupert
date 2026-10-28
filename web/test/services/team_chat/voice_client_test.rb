# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class TeamChatVoiceClientTest < ActiveSupport::TestCase
  setup do
    @url = ENV['RUPERT_VOICE_URL']
    @token = ENV['RUPERT_VOICE_TOKEN']
    ENV['RUPERT_VOICE_URL'] = 'http://127.0.0.1:18082'
    ENV['RUPERT_VOICE_TOKEN'] = 'x' * 32
  end

  teardown do
    ENV['RUPERT_VOICE_URL'] = @url
    ENV['RUPERT_VOICE_TOKEN'] = @token
  end

  test 'transcribes bounded audio through the local authenticated worker' do
    stub_request(:post, 'http://127.0.0.1:18082/transcribe')
      .with(headers: { 'Authorization' => "Bearer #{'x' * 32}" }, body: 'audio bytes')
      .to_return(status: 200, body: { text: 'Hello there' }.to_json)
    assert_equal 'Hello there', TeamChat::VoiceClient.new.transcribe(StringIO.new('audio bytes'))
  end

  test 'returns only valid WAV speech for bounded message text' do
    wav = 'RIFF' + ('x' * 40)
    stub_request(:post, 'http://127.0.0.1:18082/speak').to_return(status: 200, body: { audio: Base64.strict_encode64(wav) }.to_json)
    assert_equal wav, TeamChat::VoiceClient.new.speak('Hello')
    assert_raises(TeamChat::VoiceClient::Error) { TeamChat::VoiceClient.new.speak('x' * 4001) }
  end

  test 'refuses nonlocal endpoints and oversized recordings' do
    ENV['RUPERT_VOICE_URL'] = 'http://example.com:18082'
    refute TeamChat::VoiceClient.configured?
    assert_raises(TeamChat::VoiceClient::Error) { TeamChat::VoiceClient.new.transcribe(StringIO.new('x')) }
    ENV['RUPERT_VOICE_URL'] = 'http://127.0.0.1:18082'
    assert_raises(TeamChat::VoiceClient::Error) { TeamChat::VoiceClient.new.transcribe(StringIO.new('x' * (TeamChat::VoiceClient::MAX_AUDIO + 1))) }
  end
end
