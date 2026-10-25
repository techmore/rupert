# frozen_string_literal: true

require_relative 'fake_buzz_relay'

# Starts the in-process stand-in relay (127.0.0.1, see FakeBuzzRelay) and points
# the test workspace's Buzz settings at it. No test talks to a real relay.
module BuzzChatHelper
  CHANNEL = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
  OTHER_CHANNEL = '1b2c3d4e-5f60-4a7b-8c8d-0f1a2b3c4d5e'

  def start_buzz_relay(**options)
    Current.tenant = tenants(:default_tenant)
    Buzz::Identity.generate_keypair!
    @relay = FakeBuzzRelay.new(channel: CHANNEL, **options).start
    Buzz::Settings.set(Buzz::Settings::RELAY_URL, @relay.url)
    Buzz::Settings.set(Buzz::Settings::CHANNEL, CHANNEL)
    @alice = FakeBuzzRelay.keypair
    @bob = FakeBuzzRelay.keypair
    @relay
  end

  def stop_buzz_relay
    @relay&.stop
    Current.tenant ||= tenants(:default_tenant)
    Buzz::Settings::KEYS.each { |key| Buzz::Settings.set(key, nil) }
    Current.reset
  end

  # The relay's channel metadata (kind 39000) and member list (kind 39002) events
  # for a channel, signed by a stand-in relay key. members are pubkeys; the Rupert
  # identity is added unless member_agent is false.
  def add_channel(id, name, members: [], member_agent: true, type: 'stream', archived: false, about: nil)
    @relay_key ||= FakeBuzzRelay.keypair
    meta_tags = [['d', id], ['name', name], ['public'], ['t', type]]
    meta_tags << ['about', about] if about
    meta_tags << ['archived', 'true'] if archived
    agent = Buzz::Identity.public_key_hex
    people = (member_agent ? [agent] : []) + members
    list_tags = [['d', id], ['t', type]] + people.map { |pk| ['p', pk, '', pk == agent ? 'bot' : 'member'] }
    @relay.add(FakeBuzzRelay.signed(@relay_key, kind: 39_000, content: '', tags: meta_tags))
    @relay.add(FakeBuzzRelay.signed(@relay_key, kind: 39_002, content: '', tags: list_tags))
  end

  # The workspace's Rupert identity, read in the workspace (requests reset Current).
  def rupert_pubkey = Current.set(tenant: tenants(:default_tenant)) { Buzz::Identity.public_key_hex }

  def rupert_private_key = Current.set(tenant: tenants(:default_tenant)) { Buzz::Identity.private_key_hex }

  # The Rupert identity as a keypair the relay helpers can sign with.
  def agent_key
    { private_key: Buzz::Identity.private_key, public_key: Buzz::Identity.public_key_hex }
  end
end
