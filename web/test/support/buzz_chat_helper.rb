# frozen_string_literal: true

require_relative 'fake_buzz_relay'

# Starts the in-process Buzz relay and points Rupert's Buzz settings at it.
module BuzzChatHelper
  CHANNEL = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'

  def start_buzz_relay(**options)
    Current.tenant = tenants(:default_tenant)
    BuzzAgent.generate_keypair!
    @relay = FakeBuzzRelay.new(channel: CHANNEL, **options).start
    EnvStore.set('BUZZ_RELAY_URL', @relay.url)
    EnvStore.set('BUZZ_CHANNEL', CHANNEL)
    @alice = FakeBuzzRelay.keypair
    @bob = FakeBuzzRelay.keypair
    @relay
  end

  def stop_buzz_relay
    @relay&.stop
    %w[BUZZ_RELAY_URL BUZZ_CHANNEL BUZZ_PRIVATE_KEY FEEDBACK_READY_SENDERS].each { |key| EnvStore.set(key, nil) }
    Current.reset
  end

  OTHER_CHANNEL = '1b2c3d4e-5f60-4a7b-8c8d-0f1a2b3c4d5e'

  # The relay's channel metadata (kind 39000) and member list (kind 39002) events
  # for a channel, signed by a stand-in relay key. members are pubkeys; the agent
  # is added unless member_agent is false.
  def add_channel(id, name, members: [], member_agent: true, type: 'stream', archived: false, about: nil)
    @relay_key ||= FakeBuzzRelay.keypair
    meta_tags = [['d', id], ['name', name], ['public'], ['t', type]]
    meta_tags << ['about', about] if about
    meta_tags << ['archived', 'true'] if archived
    people = (member_agent ? [BuzzAgent.public_key_hex] : []) + members
    list_tags = [['d', id], ['t', type]] + people.map { |pk| ['p', pk, '', pk == BuzzAgent.public_key_hex ? 'bot' : 'member'] }
    @relay.add(FakeBuzzRelay.signed(@relay_key, kind: 39_000, content: '', tags: meta_tags))
    @relay.add(FakeBuzzRelay.signed(@relay_key, kind: 39_002, content: '', tags: list_tags))
  end

  # The Rupert agent as a keypair the relay helpers can sign with.
  def agent_key
    { private_key: BuzzAgent.private_key, public_key: BuzzAgent.public_key_hex }
  end
end
