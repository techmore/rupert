# frozen_string_literal: true

require "test_helper"

class BuzzAgentTest < ActiveSupport::TestCase
  setup do
    Current.tenant = tenants(:default_tenant)
    BuzzAgent.generate_keypair!
    EnvStore.set("BUZZ_RELAY_URL", "wss://relay.test")
    EnvStore.set("BUZZ_CHANNEL", "channel-id-123")
  end

  teardown do
    Current.tenant = nil
    EnvStore.set("BUZZ_RELAY_URL", nil)
    EnvStore.set("BUZZ_PRIVATE_KEY", nil)
    EnvStore.set("BUZZ_CHANNEL", nil)
  end

  test "generate_keypair stores a private key and exposes the agent npub" do
    assert_equal 64, BuzzAgent.private_key_hex.length
    assert_match(/\Anpub1/, BuzzAgent.agent_npub)
  end

  test "build_event signs a valid channel message with the channel tag" do
    event = BuzzAgent.build_event(content: "hello", channel: "channel-id-123")
    assert_equal 42, event.kind
    assert_includes event.tags, ["e", "channel-id-123"]
    assert event.verify_signature
    assert_equal BuzzAgent.public_key.to_s, event.pubkey.to_s
  end

  test "build_event defaults to a text note without a channel" do
    event = BuzzAgent.build_event(content: "hello")
    assert_equal 1, event.kind
    assert event.verify_signature
  end

  test "notify returns an error when not configured" do
    EnvStore.set("BUZZ_PRIVATE_KEY", nil)
    ok, message = BuzzAgent.notify("hi")
    refute ok
    assert_match(/not configured/, message)
  end

  test "publish sends the signed event and returns ok" do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    sent = nil
    fake.define_singleton_method(:send) do |data|
      sent = data
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(["OK", payload[1]["id"], true, ""].to_json))
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, message = BuzzAgent.publish(BuzzAgent.build_event(content: "hi", channel: "c"))
    assert ok
    assert_includes sent, "EVENT"
    assert_equal "OK", message
  end

  test "publish returns the relay rejection" do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    fake.define_singleton_method(:send) do |data|
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(["OK", payload[1]["id"], false, "rate limited"].to_json))
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, message = BuzzAgent.publish(BuzzAgent.build_event(content: "hi"))
    refute ok
    assert_equal "rate limited", message
  end

  test "publish returns an error when the relay cannot be reached" do
    WebSocket::Client::Simple.stubs(:connect).raises(StandardError, "connection refused")
    ok, message = BuzzAgent.publish(BuzzAgent.build_event(content: "hi"))
    refute ok
    assert_equal "connection refused", message
  end

  test "register publishes a kind 0 profile event" do
    fake = Object.new
    handlers = {}
    fake.define_singleton_method(:on) { |event, &blk| handlers[event] = blk }
    fake.define_singleton_method(:open?) { true }
    sent = nil
    fake.define_singleton_method(:send) do |data|
      sent = data
      payload = JSON.parse(data)
      handlers[:message]&.call(Struct.new(:data).new(["OK", payload[1]["id"], true, ""].to_json))
    end
    fake.define_singleton_method(:close) {}

    WebSocket::Client::Simple.stubs(:connect).returns(fake)
    ok, _ = BuzzAgent.register!
    assert ok
    event = JSON.parse(sent)[1]
    assert_equal 0, event["kind"]
    assert_match(/"name":"Rupert"/, event["content"])
  end
end
