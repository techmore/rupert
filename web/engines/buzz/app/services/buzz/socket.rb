# frozen_string_literal: true

require 'io/wait'
require 'json'
require 'openssl'
require 'socket'
require 'uri'
require 'websocket/driver'

module Buzz
  # A small blocking WebSocket client for the relay, on websocket-driver (already
  # bundled with Action Cable), so the module adds no gem. One connection per
  # call, no background threads: open, exchange a few frames, close. wss:// is
  # verified TLS. Frames are JSON arrays (Nostr messages); anything else is skipped.
  class Socket
    class Error < StandardError; end

    READ_CHUNK = 16_384
    MAX_BUFFERED = 2_000

    attr_reader :url

    def self.open(url, timeout:)
      new(url).tap { |socket| socket.connect(timeout) }
    end

    def initialize(url)
      @url = url
      @frames = []
      @open = false
      @closed = false
    end

    def connect(timeout)
      uri = URI.parse(url)
      secure = uri.scheme == 'wss'
      raise Error, 'the relay address is not a ws:// or wss:// address' unless %w[ws wss].include?(uri.scheme) && uri.host.present?

      deadline = now + timeout
      tcp = ::Socket.tcp(uri.host, uri.port || (secure ? 443 : 80), connect_timeout: timeout)
      @io = secure ? tls(tcp, uri.host, deadline) : tcp
      @driver = WebSocket::Driver.client(self, max_length: 4 * 1024 * 1024)
      @driver.on(:open) { @open = true }
      @driver.on(:message) { |event| @frames << event.data if @frames.size < MAX_BUFFERED }
      @driver.on(:close) { @closed = true }
      @driver.on(:error) { @closed = true }
      @driver.start
      pump(deadline) until @open || @closed || now > deadline
      raise Error, 'the relay did not accept the connection' unless @open
    end

    # Called by the driver with bytes to send.
    def write(data)
      @io.write(data)
    end

    def send_json(frame)
      raise Error, 'the relay closed the connection' if @closed

      @driver.text(frame.to_json)
    end

    # The next Nostr message as an array, ['CLOSE'] once the relay hung up, or nil
    # when nothing arrived before the deadline.
    def next_frame(deadline)
      loop do
        while (raw = @frames.shift)
          frame = parse(raw)
          return frame if frame
        end
        return ['CLOSE'] if @closed
        return nil if now >= deadline

        pump(deadline)
      end
    end

    def close
      @driver&.close
      @io&.close
    rescue StandardError
      nil
    end

    private

    def pump(deadline)
      pending = @io.respond_to?(:pending) && @io.pending.positive?
      return unless pending || @io.to_io.wait_readable([deadline - now, 0.01].max)

      data = @io.read_nonblock(READ_CHUNK, exception: false)
      return if %i[wait_readable wait_writable].include?(data)

      data.nil? ? (@closed = true) : @driver.parse(data)
    rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      @closed = true
    end

    def tls(tcp, host, deadline)
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = host
      ssl.sync_close = true
      loop do
        result = ssl.connect_nonblock(exception: false)
        break if result == ssl

        raise Error, 'the relay did not answer in time' if now > deadline

        result == :wait_readable ? tcp.wait_readable(0.1) : tcp.wait_writable(0.1)
      end
      ssl
    end

    def parse(raw)
      frame = JSON.parse(raw.to_s)
      frame.is_a?(Array) ? frame : nil
    rescue JSON::ParserError
      nil
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
