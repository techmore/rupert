# frozen_string_literal: true

require "json"
require "timeout"

# An independent opencode-powered agent in the Buzz channel. It holds its own
# Nostr identity (OPCODE_BUZZ_PRIVATE_KEY), subscribes to the channel, and when
# it's mentioned ("@opencode") it asks the installed opencode CLI
# (deepseek-v4-flash via the OpenCode Go API) to reply, then posts the answer.
# Runs as its own process under systemd (bin/opencode_agent).
class OpencodeChatAgent
  NAME = "opencode"
  STATE_FILE = Rails.root.join("tmp", "opencode_agent_state.json")

  class << self
    def run!
      new.run!
    end
  end

  def run!
    setup!
    loop do
      begin
        listen_once
      rescue StandardError => e
        Rails.logger.error "[OpencodeAgent] #{e.class}: #{e.message}"
      end
      sleep 5
    end
  end

  # --- Handler-facing methods (invoked from the WS callback with an explicit
  # receiver, so they must be public). ---

  def filters(since)
    [{ kinds: [9], "#h": [@channel], since: since }]
  end

  def process_event(event)
    return if event["pubkey"] == @pubkey

    Current.tenant = @tenant
    content = event["content"].to_s
    return unless content.downcase.include?("@#{NAME}")

    reply = generate_reply(content)
    publish_reply(reply, event)
  rescue StandardError => e
    Rails.logger.error "[OpencodeAgent] process_event: #{e.class}: #{e.message}"
  end

  private

  def setup!
    @tenant = Tenant.find_by(status: "active") || Tenant.first
    raise "No tenant found" if @tenant.nil?

    Current.tenant = @tenant
    key_hex = EnvStore.fetch("OPCODE_BUZZ_PRIVATE_KEY", "").to_s.strip
    @relay = EnvStore.fetch("BUZZ_RELAY_URL", "").to_s.strip
    @channel = EnvStore.fetch("BUZZ_CHANNEL", "").to_s.strip
    raise "Opencode agent not configured (key/relay/channel)" if key_hex.blank? || @relay.blank? || @channel.blank?

    @priv = Nostr::PrivateKey.new(key_hex)
    @pub = Nostr::PublicKey.new(Nostr::Keygen.new.extract_public_key(@priv))
    @pubkey = @pub.to_s
    Rails.logger.info "[OpencodeAgent] listening as #{@pubkey[0, 12]} on #{@relay} channel #{@channel}"
  end

  def listen_once
    require "websocket-client-simple"

    since = state_since
    authed = false
    agent = self
    ws = WebSocket::Client::Simple.connect(@relay)

    ws.on(:message) do |m|
      begin
        data = JSON.parse(m.data.to_s)
        case data[0]
        when "AUTH"
          next if authed

          authed = true
          auth = NostrPublisher.build_auth_event(@relay, data[1], @priv, @pub)
          ws.send(["AUTH", auth.to_h].to_json)
          ws.send(["REQ", "opencode", *agent.filters(since)].to_json)
        when "EVENT"
          agent.process_event(data[2])
        end
      rescue StandardError => e
        Rails.logger.error "[OpencodeAgent] handler: #{e.class}: #{e.message}"
      end
    end
    ws.on(:error) { |e| Rails.logger.warn "[OpencodeAgent] ws error: #{e.message}" }

    Timeout.timeout(10) { sleep 0.1 until ws.open? }
    sleep 1
    ws.send(["REQ", "opencode", *agent.filters(since)].to_json) unless authed

    loop do
      sleep 2
      break unless ws.open?
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

  def generate_reply(content)
    prompt = <<~PROMPT
      You are "Opencode", an AI assistant who lives in the business chat of a
      company running an inventory/ERP system called Rupert (Shopify + Square
      sync, manual counts, stock alerts). You have general knowledge but no live
      access to their data unless you can actually derive it from the message.
      A user sent this message directed at you:

      "#{content}"

      Reply helpfully and concisely (1-4 sentences), in character as a capable
      teammate. Do not claim access you don't have; if you can't know, say so
      and suggest the person ping @rupert for app data.
    PROMPT
    output = IO.popen(["opencode", "run", prompt], err: [:child, :out], &:read)
    output.to_s.strip
  rescue StandardError => e
    Rails.logger.error "[OpencodeAgent] opencode run failed: #{e.message}"
    "Sorry — I hit an error generating a reply. Try again in a moment."
  end

  def publish_reply(reply, event)
    return if reply.blank?

    tags = []
    tags << ["e", event["id"], @relay, "reply"] if event["id"]
    tags << ["p", event["pubkey"]] if event["pubkey"]
    tags << ["h", @channel]

    event = NostrPublisher.build_event(private_key: @priv, public_key: @pub,
      kind: 9, content: reply, tags: tags)
    ok, msg = NostrPublisher.publish(relay: @relay, private_key: @priv, public_key: @pub, event: event)
    Rails.logger.info "[OpencodeAgent] replied to #{event.id.to_s[0, 12]}: #{msg}"
    advance_state(event.created_at)
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
