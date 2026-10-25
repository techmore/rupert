# frozen_string_literal: true

require 'securerandom'

module Buzz
  # Rupert's side of the relay conversation: connect as the Rupert identity,
  # answer the NIP-42 challenge, then either one REQ (stored events until EOSE)
  # or one EVENT (until the relay's OK for that event's own id).
  #
  # Protocol, checked against github.com/block/buzz (ARCHITECTURE.md, 2026-10-22):
  #   * the relay sends ["AUTH", challenge] on connect; EVENT and REQ before a
  #     successful AUTH are refused, so nothing is sent before the relay's OK;
  #   * a channel REQ carries "#h": [channel uuid]; a key that is not a member gets
  #     ["CLOSED", sub, "restricted: ..."];
  #   * at most 500 stored events per filter, newest first, then ["EOSE", sub].
  #
  # Failures are Buzz::RelayClient::Error with a short reason that never holds a key.
  class RelayClient
    class Error < StandardError; end

    MAX_EVENTS = 600
    CONNECT_TIMEOUT = 6
    AUTH_WAIT = 5.0

    class << self
      def query(filters, timeout: 10) = new.query(filters, timeout: timeout)

      # [true, message] or [false, reason]; never raises.
      def publish(event, timeout: 10) = new.publish(event, timeout: timeout)
    end

    def query(filters, timeout: 10)
      session do |socket|
        sub = "rupert-#{SecureRandom.hex(4)}"
        socket.send_json(['REQ', sub, *Array(filters)])
        collect(socket, sub, deadline(timeout))
      end
    end

    def publish(event, timeout: 10)
      session do |socket|
        socket.send_json(['EVENT', event.to_h])
        acknowledgement(socket, event.id.to_s, deadline(timeout))
      end
    rescue Error => e
      [false, e.message]
    end

    private

    def session
      raise Error, 'Buzz is not set up yet' unless Identity.configured?

      relay = Identity.relay_url
      socket = Buzz::Socket.open(relay, timeout: CONNECT_TIMEOUT)
      authenticate(socket, relay)
      yield socket
    rescue Error
      raise
    rescue Buzz::Socket::Error => e
      raise Error, e.message
    rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError
      raise Error, 'the relay is not reachable'
    rescue StandardError => e
      raise Error, "could not talk to the relay (#{e.class.name.demodulize})"
    ensure
      socket&.close
    end

    # Waits for the challenge and answers it. A relay that never challenges is
    # fine: the request is then sent unauthenticated.
    def authenticate(socket, relay)
      wait = deadline(AUTH_WAIT)
      challenge = nil
      while challenge.nil?
        frame = socket.next_frame(wait)
        return if frame.nil?
        raise Error, 'the relay closed the connection' if frame[0] == 'CLOSE'

        challenge = frame[1] if frame[0] == 'AUTH'
      end
      auth = Identity.build_auth_event(challenge, relay: relay)
      socket.send_json(['AUTH', auth.to_h])
      loop do
        frame = socket.next_frame(wait)
        return if frame.nil?
        raise Error, 'the relay closed the connection' if frame[0] == 'CLOSE'
        next unless frame[0] == 'OK' && frame[1] == auth.id
        return if frame[2] == true

        raise Error, "the relay refused Rupert's sign-in (#{frame[3].to_s[0, 80]})"
      end
    end

    def collect(socket, sub, until_at)
      events = []
      loop do
        frame = socket.next_frame(until_at)
        raise Error, 'the relay did not answer in time' if frame.nil?

        case frame[0]
        when 'EVENT' then events << frame[2] if frame[1] == sub && frame[2].is_a?(Hash) && events.size < MAX_EVENTS
        when 'EOSE' then return events if frame[1] == sub
        when 'CLOSED' then raise Error, closed_reason(frame[2]) if frame[1] == sub
        when 'CLOSE' then raise Error, 'the relay closed the connection'
        end
      end
    end

    def acknowledgement(socket, event_id, until_at)
      loop do
        frame = socket.next_frame(until_at)
        return [false, 'the relay did not answer in time'] if frame.nil?
        return [false, 'the relay closed the connection'] if frame[0] == 'CLOSE'
        next unless frame[0] == 'OK' && frame[1] == event_id

        return frame[2] == true ? [true, frame[3].presence || 'OK'] : [false, frame[3].to_s.presence&.first(200) || 'the relay refused the message']
      end
    end

    def closed_reason(text)
      reason = text.to_s.tr("\n", ' ')[0, 80]
      return 'Rupert is not a member of this channel (add its public key to the channel in Buzz)' if reason.start_with?('restricted')
      return 'the relay would not let Rupert read (sign-in refused)' if reason.start_with?('auth-required')

      "the relay refused the request (#{reason})"
    end

    def deadline(seconds) = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  end
end
