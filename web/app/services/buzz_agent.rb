# frozen_string_literal: true

require "json"
require "timeout"

# Rupert's Buzz (Nostr) agent identity. Rupert holds a Nostr keypair, and this
# service signs events as that agent and publishes them to the configured Buzz
# relay — typically into a channel so humans and agents share the room.
#
# Configuration (Settings page / EnvStore):
#   BUZZ_RELAY_URL   wss://your-buzz-relay
#   BUZZ_PRIVATE_KEY the agent's nsec/hex private key (generated in Settings)
#   BUZZ_CHANNEL     the channel's Nostr event id (kind 40) to post into
class BuzzAgent
  class << self
    def configured?
      relay_url.present? && private_key_hex.present?
    end

    def relay_url
      EnvStore.fetch("BUZZ_RELAY_URL", "").to_s.strip
    end

    def private_key_hex
      EnvStore.fetch("BUZZ_PRIVATE_KEY", "").to_s.strip
    end

    def channel_id
      EnvStore.fetch("BUZZ_CHANNEL", "").to_s.strip
    end

    def private_key
      @private_key ||= Nostr::PrivateKey.new(private_key_hex)
    end

    def public_key_hex
      @public_key_hex ||= Nostr::Keygen.new.extract_public_key(private_key)
    end

    def public_key
      @public_key ||= Nostr::PublicKey.new(public_key_hex)
    end

    def agent_npub
      return nil unless private_key_hex.present?

      public_key.to_bech32
    rescue StandardError
      nil
    end

    # Generates and stores a fresh keypair for the Rupert agent.
    def generate_keypair!
      pair = Nostr::Keygen.new.generate_key_pair
      EnvStore.set("BUZZ_PRIVATE_KEY", pair.private_key)
      @private_key = @public_key = @public_key_hex = nil
      pair
    end

    # Builds and signs an event. Kind 9 (NIP-29 group chat, tagged with the
    # channel's `h` id) when a channel is given, otherwise a kind 1 text note.
    def build_event(content:, kind: nil, channel: nil, tags: [])
      kind ||= channel.present? ? 9 : 1
      h_tag = channel.present? ? [["h", channel]] : []
      event = Nostr::Event.new(pubkey: public_key, kind: kind,
        content: content.to_s, tags: h_tag + Array(tags))
      event.sign(private_key)
      event
    end

    # Publishes a message to Buzz. Returns [true, message] on success.
    # Never raises — failures are returned so callers can notify gracefully.
    def notify(content, channel: channel_id, tags: [])
      return [false, "Buzz is not configured (set BUZZ_RELAY_URL and BUZZ_PRIVATE_KEY)"] unless configured?

      event = build_event(content: content, channel: channel, tags: tags)
      publish(event)
    end

    # Publishes a kind 0 profile so the relay syncs Rupert into its users table.
    # Buzz cannot add an identity to a channel until it has seen this event.
    def register!
      return [false, "Buzz is not configured (set BUZZ_RELAY_URL and BUZZ_PRIVATE_KEY)"] unless configured?

      profile = {
        name: "Rupert",
        display_name: "Rupert",
        about: "Rupert inventory & ops agent for Herbal Healers",
        nip05: ""
      }.to_json
      publish(build_event(kind: 0, content: profile))
    end

    # Opens a WebSocket to the relay, authenticates (NIP-42) against the
    # challenge Buzz sends on connect, publishes the event, and waits for the
    # NIP-01 OK acknowledgement.
    def publish(event)
      require "websocket-client-simple"

      ack = nil
      authed = false
      sent_event = false
      relay = relay_url
      ws = WebSocket::Client::Simple.connect(relay)

      ws.on(:message) do |msg|
        begin
          data = JSON.parse(msg.data.to_s)
          case data[0]
          when "AUTH"
            unless authed
              authed = true
              # This block is evaluated with `self` = the WebSocket client, so
              # call the class method explicitly rather than by message send.
              ws.send(["AUTH", BuzzAgent.build_auth_event(data[1], relay: relay).to_h].to_json)
              ws.send(["EVENT", event.to_h].to_json) if sent_event
            end
          when "OK"
            ack = data
          end
        rescue StandardError
          nil
        end
      end
      ws.on(:error) { |e| ack ||= ["ERROR", e.message.to_s[0, 200]] }

      Timeout.timeout(8) { sleep 0.05 until ws.open? || ack }
      raise "could not connect to #{relay}" if ack.nil? && !ws.open?

      # Buzz sends its NIP-42 challenge immediately on connect — wait for it
      # (with a generous fallback for relays that don't challenge) so the first
      # EVENT is published as an authenticated session.
      deadline = Time.current + 5.0
      sleep 0.05 until authed || Time.current > deadline

      sent_event = true
      ws.send(["EVENT", event.to_h].to_json)
      Timeout.timeout(8) { sleep 0.05 until ack }

      ok = ack && ack[2] == true
      ok ? [true, ack[3].presence || "OK"] : [false, (ack && ack[3]).presence || "no acknowledgement from relay"]
    rescue StandardError => e
      [false, e.message.to_s[0, 200]]
    ensure
      begin
        ws&.close
      rescue StandardError
        nil
      end
    end

    # NIP-42 auth response: a signed kind 22242 event echoing the challenge.
    # `relay` must be captured on the calling thread — CurrentAttributes are
    # thread-local, and the WebSocket handler runs on a different thread.
    def build_auth_event(challenge, relay: relay_url)
      event = Nostr::Event.new(pubkey: public_key, kind: 22242, content: "",
        tags: [["relay", relay], ["challenge", challenge.to_s]])
      event.sign(private_key)
      event
    end
  end
end
