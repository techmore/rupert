# frozen_string_literal: true

require 'uri'

module Buzz
  # The module's configuration, per workspace, in Rupert's encrypted settings
  # store (the Setting rows that hold every other connection's credentials). The
  # key names are the ones the retired integration used, so a workspace that kept
  # its rows picks them up again. Nothing here is ever read from the repository.
  #
  #   BUZZ_RELAY_URL   ws:// or wss:// address of the team's relay
  #   BUZZ_CHANNEL     the default channel's id (a UUID in Buzz)
  #   BUZZ_PRIVATE_KEY the Rupert identity's key; generated on the Setup page, never shown
  module Settings
    RELAY_URL = 'BUZZ_RELAY_URL'
    CHANNEL = 'BUZZ_CHANNEL'
    PRIVATE_KEY = 'BUZZ_PRIVATE_KEY'
    KEYS = [RELAY_URL, CHANNEL, PRIVATE_KEY].freeze
    CHANNEL_UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    class Invalid < StandardError; end

    class << self
      def fetch(key)
        raise ArgumentError, 'Not a Buzz setting' unless KEYS.include?(key)
        return '' unless Current.tenant_id

        rows[key]&.value.to_s.strip
      rescue ActiveRecord::Encryption::Errors::Decryption
        ''
      end

      def set(key, value)
        raise ArgumentError, 'Not a Buzz setting' unless KEYS.include?(key)
        raise Invalid, 'An active workspace is required.' unless Current.tenant_id

        Current.metadata.delete(:buzz_settings)
        if value.blank?
          Setting.where(key: key, tenant_id: Current.tenant_id).delete_all
        else
          Setting.find_or_create_for(key, Current.tenant_id) { |setting| setting.value = value.to_s }
        end
      end

      # Saves the relay address and channel from the Setup form. Blank clears.
      def update!(relay_url:, channel:)
        relay_url = relay_url.to_s.strip
        channel = channel.to_s.strip.downcase
        raise Invalid, 'Enter the relay address as ws:// or wss:// with a host name.' unless relay_url.empty? || valid_relay?(relay_url)
        raise Invalid, 'Enter the channel id as it appears in Buzz (a UUID).' unless channel.empty? || channel.match?(CHANNEL_UUID)

        set(RELAY_URL, relay_url.presence)
        set(CHANNEL, channel.presence)
      end

      def valid_relay?(value)
        uri = URI.parse(value.to_s)
        %w[ws wss].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end

      private

      # The three rows, read once per request or job (set clears it).
      def rows
        cache = (Current.metadata[:buzz_settings] ||= {})
        cache[Current.tenant_id] ||= Setting.where(key: KEYS, tenant_id: Current.tenant_id).index_by(&:key)
      end
    end
  end
end
