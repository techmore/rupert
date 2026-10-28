# frozen_string_literal: true

require 'test_helper'

class TeamChatVoiceE2ETest < ActionDispatch::IntegrationTest
  setup do
    skip 'Set RUPERT_VOICE_E2E=1 with the local prototype worker to run.' unless ENV['RUPERT_VOICE_E2E'] == '1'
    WebMock.disable!
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    post login_path, params: { email: @admin.email, password: 'password' }
    TeamChat::Room.ensure_defaults!(@admin)
  end

  teardown do
    WebMock.enable! if ENV['RUPERT_VOICE_E2E'] == '1'
    Current.reset
  end

  test 'real speech worker, chat persistence and spoken saved reply' do
    upload = Rack::Test::UploadedFile.new('/tmp/rupert-voice-test.wav', 'audio/wav')
    post transcribe_team_chat_voice_path("rupert-#{@admin.id}"), params: { audio: upload }
    assert_response :success
    transcript = response.parsed_body.fetch('text')
    assert_match(/hello/i, transcript)
    post team_chat_messages_path("rupert-#{@admin.id}"), params: { body: transcript }, as: :json
    assert_response :created
    person, reply = response.parsed_body.fetch('messages')
    assert_equal transcript, person['body']
    message = TeamChat::Message.find(reply.fetch('id'))
    if ENV['RUPERT_VOICE_E2E_REAL_AGENT'] == '1'
      TeamChat::ReplyJob.perform_now(message.id)
      assert_equal 'done', message.reload.status
      assert message.body.present?
    else
      message.update!(status: 'done', body: 'Hello. The answer is forty two.')
    end
    answer = message.body
    post speak_team_chat_message_path("rupert-#{@admin.id}", message.id)
    assert_response :success
    assert_equal 'audio/wav', response.media_type
    assert response.body.start_with?('RIFF')
    assert_equal answer, message.reload.body
  end

  test 'channel recording hands off to the askers saved private reply' do
    upload = Rack::Test::UploadedFile.new('/tmp/rupert-voice-test.wav', 'audio/wav')
    post transcribe_team_chat_voice_path('admins'), params: { audio: upload }
    assert_response :success
    transcript = response.parsed_body.fetch('text')
    post team_chat_messages_path('admins'), params: { body: "@rupert #{transcript}" }, as: :json
    assert_response :created
    person, redirect = response.parsed_body.fetch('messages')
    TeamChat::ReplyJob.perform_now(redirect.fetch('id'))

    Current.tenant = @tenant
    private_room = TeamChat::Room.direct_for(@admin)
    reply = private_room.messages.where(author_kind: 'assistant').order(:id).last
    assert_equal person.fetch('id'), reply.meta['source_trigger_id']
    assert_equal "@rupert #{transcript}", private_room.messages.find(reply.meta['trigger_id']).body
    if ENV['RUPERT_VOICE_E2E_REAL_AGENT'] == '1'
      TeamChat::ReplyJob.perform_now(reply.id)
      Current.tenant = @tenant
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      while reply.reload.pending? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.2
      end
      assert_equal 'done', reply.reload.status, "private run: #{TeamChat::Run.unscoped.find_by(message_id: reply.id)&.state}"
    else
      reply.update!(status: 'done', body: 'Hello. The answer is forty two.')
    end
    get team_chat_voice_handoff_path('admins', person.fetch('id'))
    assert_response :success
    assert_equal speak_team_chat_message_path(private_room, reply), response.parsed_body.fetch('speech_url')
    post response.parsed_body.fetch('speech_url')
    assert_response :success
    assert response.body.start_with?('RIFF')
    assert reply.reload.body.present?
  end
end
