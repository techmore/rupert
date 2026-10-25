# frozen_string_literal: true

module Buzz
  # Public links for people's own Buzz apps: open the team channel, add the
  # workspace, download the desktop app. Built from public values only (relay
  # address, channel id, workspace name), URL-encoded, on the buzz: scheme.
  # Each person signs in to Buzz with their own identity; no key is involved.
  module Connect
    RELEASES_URL = 'https://github.com/block/buzz/releases/latest'

    class << self
      def relay_url
        value = Identity.relay_url
        Settings.valid_relay?(value) ? value : nil
      end

      def channel_id
        value = Identity.channel_id
        value.match?(Settings::CHANNEL_UUID) ? value : nil
      end

      # Opens the default channel in the Buzz desktop app.
      def chat_url
        "buzz://channel/#{ERB::Util.url_encode(channel_id)}" if relay_url && channel_id
      end

      # Adds this workspace to a Buzz app.
      def connect_url
        return unless relay_url

        "buzz://add-community?relay=#{ERB::Util.url_encode(relay_url)}&name=#{ERB::Util.url_encode(workspace_name)}"
      end

      def workspace_name = Current.tenant&.name.presence || 'Rupert'
    end
  end
end
