# frozen_string_literal: true

# Fire-and-forget publisher for Buzz notifications. Safe by construction: never
# raises, and silently no-ops when Buzz isn't configured, so an unreachable
# relay can never break a sync or a request.
class BuzzNotifyJob < ApplicationJob
  queue_as :default

  def perform(content, channel: nil, tags: [])
    return unless BuzzAgent.configured?

    BuzzAgent.notify(content, channel: channel.presence || BuzzAgent.channel_id, tags: tags)
  rescue StandardError
    nil
  end
end
