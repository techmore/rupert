# frozen_string_literal: true

require 'net/http'
require 'json'

module BankFeed
  class PlaidClient
    class Error < StandardError
      attr_reader :code

      def initialize(code = 'CONNECTION_FAILED')
        @code = code.to_s.match?(/\A[A-Z_]{1,80}\z/) ? code : 'CONNECTION_FAILED'
        super('The bank connection could not complete this request. Check setup or reconnect, then try again.')
      end
    end

    def initialize(connection)
      @connection = connection
    end

    def call(path, **body)
      raise Error.new('SETUP_REQUIRED') unless @connection.configured?
      host = { 'sandbox' => 'sandbox.plaid.com', 'production' => 'production.plaid.com' }.fetch(@connection.environment)
      uri = URI("https://#{host}/#{path}")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Plaid-Version'] = '2020-09-14'
      request.body = @connection.credentials.slice('client_id', 'secret').merge(body).to_json
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 40) { |http| http.request(request) }
      data = JSON.parse(response.body)
      raise Error.new('INVALID_RESPONSE') unless data.is_a?(Hash)
      raise Error.new(data['error_code']) unless response.is_a?(Net::HTTPSuccess)
      data
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error.new('CONNECTION_FAILED')
    end

    def verify_wells_fargo!(token)
      item = call('item/get', access_token: token).fetch('item')
      institution = call('institutions/get_by_id', institution_id: item.fetch('institution_id'), country_codes: ['US']).fetch('institution')
      raise Error.new('WRONG_INSTITUTION') unless institution.fetch('name').match?(/\AWells Fargo(?:\s|$)/i)
      item.fetch('item_id')
    rescue KeyError, NoMethodError
      raise Error.new('INVALID_RESPONSE')
    end
  end
end
