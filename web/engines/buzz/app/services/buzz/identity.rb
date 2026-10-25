# frozen_string_literal: true

require 'json'

module Buzz
  # The workspace's Rupert identity on the relay: one Nostr keypair, kept in the
  # encrypted settings store. Rupert reads the channels with it and signs what
  # people post from the Team chat page (their name in front, see Buzz::Chat).
  # The private key is never shown, logged or returned; the public key (npub) is
  # public and is what an owner adds to channels in Buzz.
  module Identity
    NAME = 'Rupert'
    ABOUT = "Rupert, the shop's back-office app. Messages from Rupert's Team chat page carry the person's name in front."

    class << self
      def configured? = relay_url.present? && private_key_hex.present?

      def relay_url = Settings.fetch(Settings::RELAY_URL)

      def channel_id = Settings.fetch(Settings::CHANNEL)

      def private_key_hex = Settings.fetch(Settings::PRIVATE_KEY)

      def private_key = Nostr::PrivateKey.new(private_key_hex)

      # Derived per key (workspaces have different keys), and cached by it.
      def public_key_hex
        hex = private_key_hex
        return '' if hex.blank?

        (@public_keys ||= {})[Digest::SHA256.hexdigest(hex)] ||= Nostr::Keygen.new.extract_public_key(Nostr::PrivateKey.new(hex)).to_s
      end

      def public_key = Nostr::PublicKey.new(public_key_hex)

      def npub
        return nil if private_key_hex.blank?

        public_key.to_bech32
      rescue StandardError
        nil
      end

      # Creates (or replaces) the identity's keypair. Returns the new npub.
      def generate_keypair!
        pair = Nostr::Keygen.new.generate_key_pair
        Settings.set(Settings::PRIVATE_KEY, pair.private_key.to_s)
        npub
      end

      # A signed event: kind 9 in a channel (its h tag) unless another kind is given.
      def build_event(content:, kind: nil, channel: nil, tags: [])
        kind ||= channel.present? ? 9 : 1
        h_tag = channel.present? ? [['h', channel]] : []
        event = Nostr::Event.new(pubkey: public_key, kind: kind, content: content.to_s, tags: h_tag + Array(tags))
        event.sign(private_key)
        event
      end

      # NIP-42 sign-in answer: a signed kind 22242 event echoing the challenge.
      def build_auth_event(challenge, relay:)
        event = Nostr::Event.new(pubkey: public_key, kind: 22_242, content: '', tags: [['relay', relay], ['challenge', challenge.to_s]])
        event.sign(private_key)
        event
      end

      # Publishes the kind 0 profile. Buzz only lets an identity into a channel
      # once the relay has seen its profile. Returns [ok, message].
      def publish_profile!
        return [false, 'Set the relay and create the identity first.'] unless configured?

        RelayClient.publish(build_event(kind: 0, content: { name: NAME, display_name: NAME, about: ABOUT }.to_json))
      end

      # Asks the relay whether it answers and knows the identity's profile.
      # Never raises; keeps the answer for the Setup page for a week.
      def check!
        status = { configured: configured?, reachable: nil, registered: nil, error: nil, checked_at: Time.current }
        if status[:configured]
          begin
            found = RelayClient.query([{ kinds: [0], authors: [public_key_hex], limit: 1 }], timeout: 8)
            status[:reachable] = true
            status[:registered] = found.any?
          rescue RelayClient::Error => e
            status[:reachable] = false
            status[:error] = e.message
          end
        end
        Rails.cache.write(status_cache_key, status, expires_in: 7.days)
        status
      end

      def last_check = Rails.cache.read(status_cache_key)

      private

      def status_cache_key = "buzz/identity-check/#{Current.tenant_id}"
    end
  end
end
