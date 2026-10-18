# frozen_string_literal: true

require 'net/http'

module Marketing
  # Platform-level Postmark account: one account token creates and verifies sender
  # domains, one server token sends. Workspaces never hold provider credentials.
  # Errors never include response bodies.
  class EmailProvider
    class Error < StandardError; end
    class NotConfigured < Error; end
    Result = Struct.new(:message_id, :error, keyword_init: true)

    class << self
      attr_writer :override

      def build
        @override || new
      end
    end

    def configured?
      account_token.present? && server_token.present?
    end

    def create_domain(name)
      call(:post, '/domains', { Name: name, ReturnPathDomain: "pm-bounces.#{name}" }, account_token)
    end

    def domain(id)
      call(:get, "/domains/#{Integer(id)}", nil, account_token)
    end

    def verify_domain(id)
      call(:put, "/domains/#{Integer(id)}/verifyDkim", nil, account_token)
      call(:put, "/domains/#{Integer(id)}/verifyReturnPath", nil, account_token)
      domain(id)
    end

    def send_batch(messages)
      rows = call(:post, '/email/batch', messages.map { |m| payload(m) }, server_token)
      raise Error, 'The email provider returned an incomplete response.' unless rows.is_a?(Array) && rows.size == messages.size

      rows.map { |row| row['ErrorCode'].to_i.zero? ? Result.new(message_id: row['MessageID']) : Result.new(error: "Provider error #{row['ErrorCode']}") }
    end

    private

    def payload(m)
      { From: m[:from], To: m[:to], Subject: m[:subject], TextBody: m[:text], MessageStream: 'broadcast',
        ReplyTo: m[:reply_to], Metadata: m[:metadata],
        Headers: [{ Name: 'List-Unsubscribe', Value: "<#{m[:unsubscribe_url]}>" },
                  { Name: 'List-Unsubscribe-Post', Value: 'List-Unsubscribe=One-Click' }] }.compact
    end

    def account_token
      ENV.fetch('POSTMARK_ACCOUNT_TOKEN', '')
    end

    def server_token
      ENV.fetch('POSTMARK_SERVER_TOKEN', '')
    end

    def call(verb, path, body, token)
      raise NotConfigured, 'Email sending is not configured for this platform.' if token.blank?

      uri = URI("https://api.postmarkapp.com#{path}")
      header = { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
      header['X-Postmark-Account-Token'] = token if path.start_with?('/domains')
      header['X-Postmark-Server-Token'] = token unless path.start_with?('/domains')
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(verb)
      request = klass.new(uri, header)
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) { |http| http.request(request) }
      raise Error, "The email provider rejected the request (#{response.code})." unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body.presence || '{}')
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, JSON::ParserError
      raise Error, 'The email provider could not be reached.'
    end
  end
end
