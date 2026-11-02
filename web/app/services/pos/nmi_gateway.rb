# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'nokogiri'

module Pos
  # NMI gateway: Collect.js token sale, void, refund and Query API reads.
  #
  # Uses NMI's classic Payment (Direct Post) API and Query API, the contracts with
  # documented production hosts (docs.nmi.com/reference/transactions-processing,
  # docs.nmi.com/reference/query; production POST URL secure.nmi.com/api/transact.php).
  # Hosts are fixed per environment; there is no runtime override. Production is
  # used only after the owner records sign-off on the POS setting (F69).
  class NmiGateway
    HOSTS = { 'sandbox' => 'https://sandbox.nmi.com', 'production' => 'https://secure.nmi.com' }.freeze
    MAX_BYTES = 512 * 1024
    ID = /\A[1-9][0-9]{0,29}\z/
    attr_reader :version, :setting

    def self.transact_url(environment) = "#{HOSTS.fetch(environment)}/api/transact.php"
    def self.query_url(environment) = "#{HOSTS.fetch(environment)}/api/query.php"
    def self.script_url(environment) = "#{HOSTS.fetch(environment)}/token/Collect.js"

    def initialize(setting)
      raise Error, 'Gateway belongs to another workspace.' unless setting.persisted? && setting.tenant_id == Current.tenant_id
      raise Error, 'NMI production needs owner sign-off in checkout setup first.' unless setting.nmi_ready_environment?

      @setting = setting
      @environment = setting.environment
      @version = setting.lock_version
      @credentials = setting.credentials
      unless %w[security_key tokenization_key merchant_company].all? { |key| @credentials[key].is_a?(String) && @credentials[key].present? }
        raise Error, 'Save the NMI security key, tokenization key and expected merchant company first.'
      end
      @fingerprint = setting.payment_fingerprint
    end

    def sandbox? = @environment == 'sandbox'

    def assert_checkout!(checkout)
      unless checkout.tenant_id == Current.tenant_id && checkout.location_id == @setting.location_id &&
          checkout.gateway_provider == 'nmi' && checkout.environment == @environment &&
          checkout.gateway_id == @setting.gateway_id && checkout.gateway_fingerprint == @fingerprint
        raise Error, 'NMI account changed. Review the original payment setup.'
      end
    end

    def merchant
      doc = query(report_type: 'profile')
      names = doc.xpath('/nm_response/merchant/company')
      unless names.one? && names.first.element_children.empty? && names.first.text == @credentials.fetch('merchant_company')
        raise Error, 'NMI merchant company did not match. No payment was sent.'
      end
      # The profile contract has no Gateway ID. Do not claim that it verifies one.
      { 'publicClientKey' => @credentials.fetch('tokenization_key') }
    end

    # Returns { 'response' => '1'|'2'|'3', 'transactionid', 'response_code', 'authcode' }.
    def charge(attempt, token)
      checkout = attempt.pos_checkout
      assert_checkout!(checkout)
      transact(type: 'sale', amount: decimal(checkout.total_cents), currency: 'USD', payment_token: token,
        orderid: attempt.invoice, order_description: sandbox? ? 'Rupert sandbox checkout' : 'Rupert retail checkout')
    end

    def void(transaction_id)
      raise Error, 'Invalid NMI transaction reference.' unless transaction_id.to_s.match?(ID)

      transact(type: 'void', transactionid: transaction_id, void_reason: 'user_cancel')
    end

    def refund(transaction_id, amount_cents)
      raise Error, 'Invalid NMI transaction reference.' unless transaction_id.to_s.match?(ID)
      raise Error, 'Refund amount must be positive.' unless amount_cents.to_i.positive?

      transact(type: 'refund', transactionid: transaction_id, amount: decimal(amount_cents))
    end

    # One transaction by our order id (and transaction id when known), or nil.
    def transaction(attempt)
      params = { report_type: 'transaction', order_id: attempt.invoice }
      params[:transaction_id] = attempt.transaction_id if attempt.transaction_id.present?
      rows = transactions(**params)
      raise Error, 'Multiple NMI payments need review; no new charge was sent.' if rows.size > 1

      rows.first
    end

    def transaction_by_id(transaction_id)
      raise Error, 'Invalid NMI transaction reference.' unless transaction_id.to_s.match?(ID)

      rows = transactions(report_type: 'transaction', transaction_id: transaction_id)
      raise Error, 'NMI returned an ambiguous transaction.' if rows.size > 1

      rows.first
    end

    # Settled transactions for a window (UTC), for settlement reconciliation.
    def settled(from:, to:)
      transactions(report_type: 'transaction', action_type: 'settle', start_date: from.utc.strftime('%Y%m%d%H%M%S'), end_date: to.utc.strftime('%Y%m%d%H%M%S'))
    end

    def decimal(cents) = format('%.2f', BigDecimal(cents.to_s) / 100)

    private

    def transactions(**params)
      query(**params).xpath('/nm_response/transaction').map { |row| parse_transaction(row) }
    end

    def parse_transaction(row)
      single = lambda do |node, key, required: true|
        nodes = node.xpath("./#{key}")
        return nil if nodes.empty? && !required
        raise Error, 'NMI transaction data is ambiguous.' unless nodes.one? && nodes.first.element_children.empty?

        nodes.first.text
      end
      values = %w[transaction_id transaction_type condition order_id currency].to_h { |key| [key, single.call(row, key)] }
      %w[cc_number cc_type authorization_code].each { |key| values[key] = single.call(row, key, required: false) }
      values['actions'] = row.xpath('./action').map do |action|
        %w[action_type success amount].to_h { |key| [key, single.call(action, key)] }
          .merge(%w[date batch_id response_code].to_h { |key| [key, single.call(action, key, required: false)] })
      end
      values
    end

    def transact(**fields)
      req = Net::HTTP::Post.new(URI(self.class.transact_url(@environment)).request_uri, 'Accept' => 'text/plain')
      req.set_form_data(fields.merge(security_key: @credentials.fetch('security_key')))
      body = request(self.class.transact_url(@environment), req).force_encoding(Encoding::UTF_8)
      raise Error, 'NMI response could not be verified. Check payment status before retrying.' unless body.valid_encoding? && body.bytesize < 8192

      doc = URI.decode_www_form(body.strip).to_h
      raise Error, 'NMI response could not be verified. Check payment status before retrying.' unless %w[1 2 3].include?(doc['response'])

      # Keep vendor text, AVS/CVV detail and raw responses out of storage and errors.
      doc.slice('response', 'transactionid', 'response_code', 'authcode')
    rescue ArgumentError
      raise Error, 'NMI response could not be verified. Check payment status before retrying.'
    end

    def query(**fields)
      req = Net::HTTP::Post.new(URI(self.class.query_url(@environment)).request_uri, 'Accept' => 'application/xml')
      req.set_form_data(fields.merge(security_key: @credentials.fetch('security_key')))
      body = request(self.class.query_url(@environment), req).force_encoding(Encoding::UTF_8)
      raise Error, 'NMI report could not be verified.' unless body.valid_encoding? && !body.match?(/<!\s*(?:DOCTYPE|ENTITY)\b/i)
      doc = Nokogiri::XML(body, nil, 'UTF-8') { |config| config.strict.nonet }
      unless doc.root&.name == 'nm_response' && doc.root.namespace.nil? && !doc.internal_subset &&
          doc.xpath('//error | //error_response').empty?
        raise Error, 'NMI report could not be verified.'
      end
      doc
    rescue Nokogiri::XML::SyntaxError, EncodingError
      raise Error, 'NMI report could not be verified.'
    end

    def request(url, req)
      uri = URI(url)
      # Fixed hosts, no proxies, redirects, retries or raw response logging.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 15
      http.write_timeout = 5
      http.max_retries = 0
      req['Accept-Encoding'] = 'identity'
      body = +''
      http.start do |session|
        session.request(req) do |response|
          raise Error, 'NMI response could not be verified. Check payment status before retrying.' unless response.code == '200'
          response.read_body do |chunk|
            raise Error, 'NMI response exceeded its limit.' if body.bytesize + chunk.bytesize > MAX_BYTES
            body << chunk
          end
        end
      end
      body
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, Net::ProtocolError
      raise Error, 'NMI outcome is unknown. Check payment status before retrying.'
    end
  end
end
