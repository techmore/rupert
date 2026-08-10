# frozen_string_literal: true

require "json"
require "timeout"

# Persistent Buzz agent: subscribes to the community channel, notices messages
# that mention Rupert, and replies. Runs as its own process under systemd
# (bin/buzz_listener); reconnects automatically and never exits fatally.
class BuzzListener
  STATE_FILE = Rails.root.join("tmp", "buzz_listener_state.json")
  KEEPALIVE_INTERVAL = 15 # seconds between client WS pings
  PONG_TIMEOUT = 45 # reconnect if no inbound relay frame in this many seconds

  class << self
    def run!
      new.run!
    end
  end

  def run!
    setup_tenant!
    loop do
      begin
        listen_once
      rescue StandardError => e
        Rails.logger.error "[BuzzListener] #{e.class}: #{e.message}"
      end
      sleep 5
    end
  end

  # --- Handler-facing methods. Called from a WebSocket callback block where
  # `self` is the WebSocket client, so they are invoked via an explicit
  # receiver and must be public. ---

  def filters(since)
    [
      { kinds: [9], "#h": [@channel], since: since },
      { kinds: [1], "#p": [@pubkey], since: since }
    ]
  end

  def process_event(event, _ws)
    return if event["pubkey"] == @pubkey

    # The WebSocket callback runs on a different thread, where Current (thread
    # local) is nil — restore the tenant so EnvStore/tenant-scoped queries work.
    Current.tenant = @tenant

    content = event["content"].to_s
    mentions_me = content.downcase.include?("@rupert") ||
      Array(event["tags"]).any? { |tag| tag[0] == "p" && tag[1] == @pubkey }
    return unless mentions_me

    reply = BuzzResponder.respond(content, mentions_me: true)
    return if reply.blank?

    ok, msg = BuzzAgent.notify(reply, channel: @channel, tags: reply_tags(event))
    Rails.logger.info "[BuzzListener] replied to #{event["id"].to_s[0, 12]}: #{msg}"
    advance_state(event["created_at"].to_i)
  rescue StandardError => e
    Rails.logger.error "[BuzzListener] process_event: #{e.class}: #{e.message}"
  end

  private

  def setup_tenant!
    tenant = Tenant.find_by(status: "active") || Tenant.first
    raise "No tenant found" if tenant.nil?

    @tenant = tenant
    Current.tenant = tenant
    @pubkey = BuzzAgent.public_key.to_s
    @channel = BuzzAgent.channel_id
    raise "Buzz not configured (relay/channel missing)" unless BuzzAgent.configured? && @channel.present?

    Rails.logger.info "[BuzzListener] listening as #{@pubkey[0, 12]} on #{BuzzAgent.relay_url} channel #{@channel}"
  end

  def listen_once
    require "websocket-client-simple"

    relay = BuzzAgent.relay_url
    since = state_since
    authed = false
    listener = self
    last_inbound = Time.now
    ws = WebSocket::Client::Simple.connect(relay)

    ws.on(:message) do |m|
      begin
        # Any inbound frame proves the relay is still talking to us.
        last_inbound = Time.now if m.respond_to?(:type)
        # Answer the relay's keepalive pings so it doesn't drop an idle socket.
        if m.respond_to?(:type) && m.type == :ping
          ws.send(m.data.to_s, type: :pong)
          next
        end
        next if m.respond_to?(:type) && m.type != :text

        data = JSON.parse(m.data.to_s)
        case data[0]
        when "AUTH"
          next if authed

          authed = true
          ws.send(["AUTH", BuzzAgent.build_auth_event(data[1], relay: relay).to_h].to_json)
          ws.send(["REQ", "rupert", *listener.filters(since)].to_json)
        when "EVENT"
          listener.process_event(data[2], ws)
        end
      rescue StandardError => e
        Rails.logger.error "[BuzzListener] handler: #{e.class}: #{e.message}"
      end
    end
    ws.on(:error) { |e| Rails.logger.warn "[BuzzListener] ws error: #{e.message}" }

    Timeout.timeout(10) { sleep 0.1 until ws.open? }
    sleep 1
    ws.send(["REQ", "rupert", *listener.filters(since)].to_json) unless authed

    # websocket-client-simple never notices a relay closing an idle connection
    # (its reader thread loops silently on EOF), so `open?` stays true and this
    # would block forever. Periodically ping the relay; drop out — letting the
    # outer loop reconnect — when it stops talking or the socket is dead.
    loop do
      sleep KEEPALIVE_INTERVAL
      break unless ws.open?

      if Time.now - last_inbound > PONG_TIMEOUT
        Rails.logger.warn "[BuzzListener] no relay traffic for #{PONG_TIMEOUT}s — reconnecting"
        break
      end

      begin
        ws.send("", type: :ping)
      rescue StandardError => e
        Rails.logger.warn "[BuzzListener] keepalive write failed: #{e.class}: #{e.message}"
        break
      end
      break if ws.closed?
    end
  rescue Timeout::Error
    nil
  ensure
    begin
      ws&.close
    rescue StandardError
      nil
    end
  end

  def reply_tags(event)
    tags = []
    tags << ["e", event["id"], BuzzAgent.relay_url, "reply"] if event["id"]
    tags << ["p", event["pubkey"]] if event["pubkey"]
    tags
  end

  def state_since
    state["since"] || (Time.now - 3600).to_i
  end

  def advance_state(created_at)
    return if created_at <= state_since

    state["since"] = created_at
    write_state
  end

  def state
    @state ||= begin
      JSON.parse(File.read(STATE_FILE))
    rescue StandardError
      { "since" => nil }
    end
  end

  def write_state
    FileUtils.mkdir_p(File.dirname(STATE_FILE))
    File.write(STATE_FILE, JSON.generate(state))
  end
end
