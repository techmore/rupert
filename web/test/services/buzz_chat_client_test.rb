# frozen_string_literal: true

require 'test_helper'
require_relative '../support/buzz_chat_helper'

# The Team chat as a Buzz client: channel list, unread markers, threads,
# reactions, mentions, and edits and deletions made elsewhere.
class BuzzChatClientTest < ActiveSupport::TestCase
  include BuzzChatHelper

  setup do
    start_buzz_relay
    @user = users(:regular_user)
    @t0 = Time.now.to_i - 3600
    add_channel(CHANNEL, 'rupert', members: [@alice[:public_key]], about: 'Rupert notices')
    add_channel(OTHER_CHANNEL, 'general', members: [@alice[:public_key], @bob[:public_key]])
  end

  teardown { stop_buzz_relay }

  def reply_tags(root, parent = nil)
    parent ? [['e', root, '', 'root'], ['e', parent, '', 'reply']] : [['e', root, '', 'reply']]
  end

  test 'the channel list is what the relay says the agent belongs to' do
    add_channel('2c3d4e5f-6071-4b8c-9d9e-1a2b3c4d5e6f', 'secret', members: [@alice[:public_key]], member_agent: false)
    add_channel('3d4e5f60-7182-4c9d-8e0f-2b3c4d5e6f70', 'forum', type: 'forum')
    add_channel('4e5f6071-8293-4d0e-9f1a-3c4d5e6f7081', 'old', archived: true)
    BuzzChat.sync!

    list = BuzzChat.channels(viewer: @user)
    assert_equal %w[rupert general], list.map { |c| c[:name] }, 'only stream channels the agent is in, the configured one first'
    assert_equal CHANNEL, list.first[:id]
    assert list.first[:default]
    assert_equal 'Rupert notices', list.first[:about]
    assert_equal [CHANNEL, OTHER_CHANNEL], BuzzChat.channel_ids.sort_by { |id| id == CHANNEL ? 0 : 1 }
  end

  test 'a channel the agent was removed from disappears after the next refresh' do
    BuzzChat.sync!
    assert_equal 2, BuzzChannel.count
    @relay.events.reject! { |e| e['kind'] == 39_002 && e['tags'].include?(['d', OTHER_CHANNEL]) }
    BuzzChannel.update_all(fetched_at: 5.minutes.ago)
    BuzzChat.sync!
    assert_equal [CHANNEL], BuzzChannel.pluck(:channel_id)
  end

  test 'messages from every channel are copied and kept apart' do
    @relay.add(@relay.message(@alice, 'in rupert', at: @t0))
    @relay.add(@relay.message(@bob, 'in general', at: @t0 + 5, channel: OTHER_CHANNEL))
    assert_equal 2, BuzzChat.sync!, BuzzChat.status[:error]

    assert_equal ['in rupert'], BuzzChat.page(channel: CHANNEL)[:messages].map { |m| m[:text] }
    assert_equal ['in general'], BuzzChat.page(channel: OTHER_CHANNEL)[:messages].map { |m| m[:text] }
    assert_equal OTHER_CHANNEL, BuzzChat.page(channel: OTHER_CHANNEL)[:messages].first[:channel]
  end

  test 'a channel the agent is not in cannot be chosen or posted to' do
    BuzzChat.sync!
    assert_nil BuzzChat.resolve_channel('99999999-9999-4999-8999-999999999999')
    assert_equal CHANNEL, BuzzChat.resolve_channel(nil)
    assert_equal OTHER_CHANNEL, BuzzChat.resolve_channel(OTHER_CHANNEL)
    assert_raises(BuzzChat::Invalid) { BuzzChat.post!(user: @user, text: 'hi', channel: '99999999-9999-4999-8999-999999999999') }
    assert_empty @relay.published
  end

  test 'unread counts start at zero, grow with other people\'s messages and reset when read' do
    @relay.add(@relay.message(@alice, 'already there', at: @t0))
    BuzzChat.sync!
    assert_equal [0, 0], BuzzChat.channels(viewer: @user).map { |c| c[:unread] }, 'the first look is not a flood'

    @relay.add(@relay.message(@alice, 'new one', at: Time.now.to_i + 1))
    @relay.add(@relay.message(@bob, 'new in general', at: Time.now.to_i + 2, channel: OTHER_CHANNEL))
    @relay.add(@relay.message(@bob, 'another in general', at: Time.now.to_i + 3, channel: OTHER_CHANNEL))
    BuzzChat.sync!
    unread = BuzzChat.channels(viewer: @user).to_h { |c| [c[:name], c[:unread]] }
    assert_equal({ 'rupert' => 1, 'general' => 2 }, unread)

    BuzzChat.post!(user: @user, text: 'my own words', channel: OTHER_CHANNEL)
    assert_equal 2, BuzzChat.channels(viewer: @user).find { |c| c[:name] == 'general' }[:unread], 'what you posted yourself is not unread'

    BuzzChat.mark_read!(@user, OTHER_CHANNEL)
    assert_equal 0, BuzzChat.channels(viewer: @user).find { |c| c[:name] == 'general' }[:unread]
    other = User.create!(tenant: Current.tenant, email: 'second-reader@example.com', role: 'admin', password: 'password123', name: 'Second')
    assert_equal [0, 0], BuzzChat.channels(viewer: other).map { |c| c[:unread] }, 'each person has their own marker'
  end

  test 'thread markers are read the way Buzz resolves them' do
    root = @relay.message(@alice, 'the root', at: @t0)
    direct = @relay.message(@bob, 'a direct reply', at: @t0 + 10, extra_tags: reply_tags(root['id']))
    nested = @relay.message(@alice, 'a nested reply', at: @t0 + 20, extra_tags: reply_tags(root['id'], direct['id']))
    lone_root = @relay.message(@bob, 'only a root marker', at: @t0 + 30, extra_tags: [['e', root['id'], '', 'root']])
    unmarked = @relay.message(@bob, 'unmarked e tag', at: @t0 + 40, extra_tags: [['e', root['id']]])
    [root, direct, nested, lone_root, unmarked].each { |e| @relay.add(e) }
    BuzzChat.sync!

    rows = BuzzMessage.all.index_by(&:content)
    assert_nil rows['the root'].thread_root
    assert_equal [root['id'], root['id']], [rows['a direct reply'].thread_root, rows['a direct reply'].reply_to]
    assert_equal [root['id'], direct['id']], [rows['a nested reply'].thread_root, rows['a nested reply'].reply_to]
    assert_nil rows['only a root marker'].thread_root, 'a lone root marker never anchors a reply'
    assert_nil rows['unmarked e tag'].thread_root
  end

  test 'the timeline holds top-level messages with reply counts and the thread holds the rest' do
    root = @relay.message(@alice, 'the root', at: @t0)
    other = @relay.message(@alice, 'another topic', at: @t0 + 5)
    [root, other,
     @relay.message(@bob, 'reply one', at: @t0 + 10, extra_tags: reply_tags(root['id'])),
     @relay.message(@alice, 'reply two', at: @t0 + 20, extra_tags: reply_tags(root['id'], root['id']))].each { |e| @relay.add(e) }
    BuzzChat.sync!

    timeline = BuzzChat.page[:messages]
    assert_equal ['the root', 'another topic'], timeline.map { |m| m[:text] }
    assert_equal [2, 0], timeline.map { |m| m[:reply_count] }
    assert_equal Time.zone.at(@t0 + 20).iso8601, timeline.first[:last_reply_at]

    thread = BuzzChat.thread(root['id'], channel: CHANNEL)
    assert_equal 'the root', thread[:root][:text]
    assert_equal ['reply one', 'reply two'], thread[:replies].map { |m| m[:text] }
    assert_equal root['id'], thread[:replies].first[:root]
    assert_equal ['the root', 'reply one', 'reply two'], BuzzChat.thread(thread[:replies].first[:id], channel: CHANNEL).then { |t| [t[:root], *t[:replies]] }.map { |m| m[:text] },
      'asking for a reply opens its thread'
    assert_nil BuzzChat.thread('f' * 64, channel: CHANNEL)
  end

  test 'opening an old thread asks the relay for replies the copy does not have' do
    root = @relay.message(@alice, 'old root', at: @t0)
    @relay.add(root)
    BuzzChat.sync!
    @relay.add(@relay.message(@bob, 'late reply', at: @t0 + 30, extra_tags: reply_tags(root['id'])))
    assert_empty BuzzChat.thread(root['id'], channel: CHANNEL)[:replies]
    assert_equal ['late reply'], BuzzChat.thread(root['id'], channel: CHANNEL, refresh: true)[:replies].map { |m| m[:text] }
  end

  test 'a reply is posted with the thread tags, always answering the thread root' do
    root = @relay.message(@alice, 'the root', at: @t0)
    reply = @relay.message(@bob, 'a reply', at: @t0 + 10, extra_tags: reply_tags(root['id']))
    [root, reply].each { |e| @relay.add(e) }
    BuzzChat.sync!

    BuzzChat.post!(user: @user, text: 'replying to the root', reply_to: root['id'])
    assert_includes @relay.published.last['tags'], ['e', root['id'], '', 'reply']
    assert_equal 1, @relay.published.last['tags'].count { |t| t[0] == 'e' }

    row = BuzzChat.post!(user: @user, text: 'replying to a reply', reply_to: reply['id'])
    assert_equal [['e', root['id'], '', 'reply']], @relay.published.last['tags'].select { |t| t[0] == 'e' }
    assert_equal [root['id'], root['id']], [row.thread_root, row.reply_to]
    assert_equal BuzzAgent.public_key_hex, @relay.published.last['pubkey'], 'still the agent, never a person'
    assert_equal ['a reply', 'replying to a reply', 'replying to the root'], BuzzChat.thread(root['id'], channel: CHANNEL)[:replies].map { |m| m[:text] }.sort

    assert_raises(BuzzChat::Invalid) { BuzzChat.post!(user: @user, text: 'to nowhere', reply_to: 'e' * 64) }
    refute_includes BuzzChat.page[:messages].map { |m| m[:text] }, 'replying to a reply', 'replies stay out of the timeline'
  end

  test 'reactions are copied, counted and attributed' do
    @relay.add(@relay.profile(@alice, display_name: 'Alice'))
    message = @relay.message(@alice, 'react to me', at: @t0)
    @relay.add(message)
    BuzzChat.sync! # copies the message
    @relay.add(FakeBuzzRelay.signed(@alice, kind: 7, content: '👍', tags: [['e', message['id']]]))
    @relay.add(FakeBuzzRelay.signed(@bob, kind: 7, content: '👍', tags: [['e', message['id']]]))
    @relay.add(FakeBuzzRelay.signed(agent_key, kind: 7, content: '🎉', tags: [['e', message['id']]]))
    @relay.add(FakeBuzzRelay.signed(@bob, kind: 7, content: '+', tags: [['e', message['id']]]))
    BuzzChat.sync!

    reactions = BuzzChat.page[:messages].first[:reactions]
    thumbs = reactions.find { |r| r[:emoji] == '👍' }
    assert_equal 3, thumbs[:count], 'a bare "+" counts as a like'
    assert reactions.find { |r| r[:emoji] == '🎉' }[:mine]
    refute thumbs[:mine]
    assert_includes thumbs[:by], 'Alice'
    assert_includes reactions.find { |r| r[:emoji] == '🎉' }[:by], 'Rupert (an administrator)'
  end

  test 'reactions that are forged, aimed at unknown messages or oversized are ignored, and taken-back ones go' do
    message = @relay.message(@alice, 'react to me', at: @t0)
    @relay.add(message)
    BuzzChat.sync!
    good = FakeBuzzRelay.signed(@bob, kind: 7, content: '👀', tags: [['e', message['id']]])
    forged = FakeBuzzRelay.signed(@bob, kind: 7, content: '❤️', tags: [['e', message['id']]]).merge('content' => '😈')
    unknown = FakeBuzzRelay.signed(@bob, kind: 7, content: '👍', tags: [['e', 'a' * 64]])
    huge = FakeBuzzRelay.signed(@bob, kind: 7, content: 'x' * 100, tags: [['e', message['id']]])
    [good, forged, unknown, huge].each { |e| @relay.add(e) }
    BuzzChat.sync!
    assert_equal ['👀'], BuzzReaction.pluck(:emoji)

    @relay.events.delete(good)
    BuzzChat.sync!
    assert_empty BuzzReaction.all, 'the relay no longer returns it, so it was taken back'
  end

  test 'react! publishes a plain NIP-25 reaction as the agent and takes it back on the second press' do
    message = @relay.message(@alice, 'react to me', at: @t0)
    @relay.add(message)
    BuzzChat.sync!

    assert_equal :added, BuzzChat.react!(user: @user, channel: CHANNEL, message: message['id'], emoji: '🎉')
    event = @relay.published.last
    assert_equal [7, '🎉', [['e', message['id']]], BuzzAgent.public_key_hex], [event['kind'], event['content'], event['tags'], event['pubkey']]
    reactions = BuzzChat.page(viewer: @user)[:messages].first[:reactions]
    assert_equal [{ emoji: '🎉', count: 1, mine: true, by: ['Rupert (an administrator)'] }], reactions

    assert_equal :removed, BuzzChat.react!(user: @user, channel: CHANNEL, message: message['id'], emoji: '🎉')
    removal = @relay.published.last
    assert_equal [5, [['e', event['id']]]], [removal['kind'], removal['tags']]
    assert_empty BuzzReaction.all
  end

  test 'reactions refuse unknown emoji, unknown messages and a flood' do
    message = @relay.message(@alice, 'react to me', at: @t0)
    @relay.add(message)
    BuzzChat.sync!
    assert_raises(BuzzChat::Invalid) { BuzzChat.react!(user: @user, channel: CHANNEL, message: message['id'], emoji: '<img>') }
    assert_raises(BuzzChat::Invalid) { BuzzChat.react!(user: @user, channel: CHANNEL, message: 'b' * 64, emoji: '👍') }
    assert_raises(BuzzChat::Invalid) { BuzzChat.react!(user: @user, channel: OTHER_CHANNEL, message: message['id'], emoji: '👍') }
    assert_empty @relay.published

    BuzzReaction::QUICK.each { |emoji| BuzzChat.react!(user: @user, channel: CHANNEL, message: message['id'], emoji: emoji) }
    (BuzzChat::REACTION_LIMIT - BuzzReaction::QUICK.size + 1).times do |i|
      BuzzReaction.create!(event_id: format('%064x', i), target_id: message['id'], channel: CHANNEL, pubkey: 'c' * 64, emoji: '👍',
        rupert_user_id: @user.id, posted_at: @t0)
    end
    BuzzReaction.where(pubkey: BuzzAgent.public_key_hex, emoji: '👍').delete_all
    assert_raises(BuzzChat::RateLimited) { BuzzChat.react!(user: @user, channel: CHANNEL, message: message['id'], emoji: '👍') }
  end

  test 'a failed reaction says so and changes nothing' do
    message = @relay.message(@alice, 'react to me', at: @t0)
    @relay.add(message)
    BuzzChat.sync!
    @relay.stop
    assert_raises(BuzzChat::PostFailed) { BuzzChat.react!(user: @user, channel: CHANNEL, message: message['id'], emoji: '👍') }
    assert_empty BuzzReaction.all
  end

  test 'members come from the channel list with names, the agent first' do
    @relay.add(@relay.profile(@alice, display_name: 'Alice A'))
    BuzzChat.sync!
    list = BuzzChat.members(CHANNEL)
    assert_equal [BuzzAgent.public_key_hex, @alice[:public_key]], list.map { |m| m[:pubkey] }
    assert list.first[:agent]
    assert_equal 'Rupert', list.first[:name]
    assert_equal 'Alice A', list.last[:name]
    assert_equal [], BuzzChat.members('99999999-9999-4999-8999-999999999999')
  end

  test 'a mention becomes a p tag only for a member whose @name is still in the text' do
    @relay.add(@relay.profile(@alice, display_name: 'Alice A'))
    BuzzChat.sync!
    stranger = FakeBuzzRelay.keypair[:public_key]
    BuzzChat.post!(user: @user, text: 'Hello @Alice A and @Rupert, also @Nobody', mentions: [@alice[:public_key], BuzzAgent.public_key_hex, stranger, @bob[:public_key]])
    tags = @relay.published.last['tags']
    assert_equal [@alice[:public_key], BuzzAgent.public_key_hex].sort, tags.select { |t| t[0] == 'p' }.map { |t| t[1] }.sort
    assert_includes @relay.published.last['content'], '@Alice A'

    BuzzChat.post!(user: @user, text: 'I deleted the name', mentions: [@alice[:public_key]])
    assert_empty @relay.published.last['tags'].select { |t| t[0] == 'p' }
  end

  test 'an edit by the author replaces the text and an edit by anyone else is ignored' do
    message = @relay.message(@alice, 'first draft', at: @t0)
    @relay.add(message)
    BuzzChat.sync!
    @relay.add(FakeBuzzRelay.signed(@bob, kind: 40_003, content: 'hijacked', tags: [['h', CHANNEL], ['e', message['id']]]))
    BuzzChat.sync!
    assert_equal 'first draft', BuzzMessage.first.content

    @relay.add(FakeBuzzRelay.signed(@alice, kind: 40_003, content: 'final draft', tags: [['h', CHANNEL], ['e', message['id']]], created_at: Time.now.to_i))
    BuzzChat.sync!
    shown = BuzzChat.page[:messages].first
    assert_equal ['final draft', true], [shown[:text], shown[:edited]]
  end

  test 'deleted messages disappear, with their reactions, but only when the deleter may' do
    mine = @relay.message(@alice, 'to be deleted', at: @t0)
    keep = @relay.message(@alice, 'to stay', at: @t0 + 5)
    moderated = @relay.message(@bob, 'moderated away', at: @t0 + 10)
    [mine, keep, moderated].each { |e| @relay.add(e) }
    BuzzChat.sync!
    @relay.add(FakeBuzzRelay.signed(@bob, kind: 7, content: '👍', tags: [['e', mine['id']]]))
    BuzzChat.sync!
    assert_equal 1, BuzzReaction.count

    @relay.add(FakeBuzzRelay.signed(@bob, kind: 5, content: '', tags: [['h', CHANNEL], ['e', keep['id']]])) # not their message
    BuzzChat.sync!
    assert_equal 3, BuzzMessage.count

    @relay.add(FakeBuzzRelay.signed(@alice, kind: 5, content: '', tags: [['h', CHANNEL], ['e', mine['id']]]))
    @relay.add(FakeBuzzRelay.signed(@alice, kind: 9005, content: '', tags: [['h', CHANNEL], ['e', moderated['id']]]))
    BuzzChat.sync!
    assert_equal ['to stay'], BuzzMessage.pluck(:content)
    assert_equal 0, BuzzReaction.count
  end

  test 'purge also clears reactions whose message is gone' do
    message = @relay.message(@alice, 'old', at: (BuzzChat::RETENTION + 1.day).ago.to_i)
    @relay.add(message)
    BuzzChat.sync!
    @relay.add(FakeBuzzRelay.signed(@bob, kind: 7, content: '👍', tags: [['e', message['id']]]))
    BuzzChat.sync!
    assert_equal 1, BuzzReaction.count
    BuzzChat.purge!
    assert_equal [0, 0], [BuzzMessage.count, BuzzReaction.count]
  end

  test 'a chat post, reply or reaction can never be the ready-for-development sender' do
    EnvStore.set('FEEDBACK_READY_SENDERS', "#{BuzzAgent.public_key_hex}, #{@alice[:public_key]}")
    BuzzChat.sync!
    root = BuzzChat.post!(user: @user, text: 'mark it ready for development', channel: OTHER_CHANNEL)
    BuzzChat.post!(user: @user, text: 'ready!', channel: OTHER_CHANNEL, reply_to: root.event_id)
    BuzzChat.react!(user: @user, channel: OTHER_CHANNEL, message: root.event_id, emoji: '✅')
    assert(@relay.published.all? { |e| e['pubkey'] == BuzzAgent.public_key_hex })
    @relay.published.each { |e| refute FeedbackIntake.ready_sender?(e['pubkey']) }
  end
end
