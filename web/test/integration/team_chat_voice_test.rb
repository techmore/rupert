# frozen_string_literal: true

require 'test_helper'

class TeamChatVoiceTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    @old_url, @old_token = ENV.values_at('RUPERT_VOICE_URL', 'RUPERT_VOICE_TOKEN')
    ENV['RUPERT_VOICE_URL'] = 'http://127.0.0.1:18082'
    ENV['RUPERT_VOICE_TOKEN'] = 'v' * 32
    post login_path, params: { email: @admin.email, password: 'password' }
    TeamChat::Room.ensure_defaults!(@admin)
  end

  teardown do
    ENV['RUPERT_VOICE_URL'], ENV['RUPERT_VOICE_TOKEN'] = @old_url, @old_token
    Current.reset
  end

  test 'transcribed speech is posted and saved through the normal chat path' do
    TeamChat::VoiceClient.any_instance.expects(:transcribe).returns('Hello Rupert')
    post transcribe_team_chat_voice_path('admins'), params: { audio: 'recording' }, as: :json
    assert_response :success
    assert_equal 'Hello Rupert', response.parsed_body['text']
    post team_chat_messages_path('admins'), params: { body: '@rupert Hello Rupert' }, as: :json
    assert_response :created
    assert_equal '@rupert Hello Rupert', response.parsed_body['messages'].first['body']
  end

  test 'only an existing finished assistant message in this room can be spoken' do
    room = TeamChat::Room.find_by!(slug: 'admins')
    answer = room.messages.create!(author_kind: 'assistant', status: 'done', body: 'Hello there')
    person = room.messages.create!(author_kind: 'person', user: @admin, body: 'Private text')
    wav = 'RIFF' + ('x' * 40)
    TeamChat::VoiceClient.any_instance.expects(:speak).with('Hello there').returns(wav)
    post speak_team_chat_message_path('admins', answer.id)
    assert_response :success
    assert_equal 'audio/wav', response.media_type
    assert_equal wav, response.body
    post speak_team_chat_message_path('admins', person.id)
    assert_response :unprocessable_entity
  end

  test 'cannot use another person’s private room' do
    other = User.create!(tenant: @tenant, email: 'voice-other@example.com', role: 'admin', password: 'password123')
    room = TeamChat::Room.direct_for(other)
    post transcribe_team_chat_voice_path(room.slug), params: { audio: 'recording' }, as: :json
    assert_response :not_found
  end

  test 'channel voice handoff exposes only the asker’s current private answer' do
    channel = TeamChat::Room.find_by!(slug: 'admins')
    trigger = channel.messages.create!(author_kind: 'person', user: @admin, body: '@rupert Hello')
    get team_chat_voice_handoff_path(channel, trigger.id)
    assert_response :success
    assert_equal 'pending', response.parsed_body['status']

    room = TeamChat::Room.direct_for(@admin)
    answer = room.messages.create!(author_kind: 'assistant', status: 'done', body: 'A private answer',
      meta: { 'asked_by' => @admin.id, 'source_trigger_id' => trigger.id, 'source_request_revision' => trigger.request_revision })
    get team_chat_voice_handoff_path(channel, trigger.id)
    assert_response :success
    assert_equal speak_team_chat_message_path(room, answer), response.parsed_body['speech_url']
    assert_not_includes response.body, 'A private answer'

    other = User.create!(tenant: @tenant, email: 'voice-owner@example.com', role: 'admin', password: 'password123')
    theirs = channel.messages.create!(author_kind: 'person', user: other, body: '@rupert Private')
    get team_chat_voice_handoff_path(channel, theirs.id)
    assert_response :not_found
  end
end
