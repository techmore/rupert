# frozen_string_literal: true

# Stubs NMI's classic Payment API (transact.php) and Query API (query.php) for
# one environment. Responses follow docs.nmi.com: transact returns a query
# string; query returns <nm_response> XML.
module NmiSandboxFixture
  def prepare_nmi_fixture(environment: 'sandbox')
    @nmi_environment = environment
    @nmi_mode = :approved
    @nmi_sales = 0
    @nmi_reversals = []
    @nmi_company = 'Sandbox Company'
    @nmi_currency = 'USD'
    @nmi_amount = '11.66'
    @nmi_condition = 'pendingsettlement'
    @nmi_order_override = nil
    @nmi_xml_override = nil
    @nmi_extra_actions = ''
    stub_request(:post, Pos::NmiGateway.transact_url(environment)).to_return do |request|
      fields = URI.decode_www_form(request.body).to_h
      assert_equal 'sandbox-private-fixture', fields.fetch('security_key')
      case fields.fetch('type')
      when 'sale'
        @nmi_sales += 1
        @nmi_invoice = fields.fetch('orderid')
        assert_equal '11.66', fields['amount']
        assert_equal 'USD', fields['currency']
        assert_equal %w[amount currency order_description orderid payment_token security_key type], fields.keys.sort
        @nmi_during_sale&.call
        raise Net::ReadTimeout if @nmi_mode == :timeout
        next { status: 200, body: '<html>Gateway temporarily unavailable</html>' } if @nmi_mode == :malformed

        approved = @nmi_mode != :declined
        { status: 200, body: URI.encode_www_form(response: approved ? '1' : '2', responsetext: approved ? 'SUCCESS' : 'DECLINE',
          authcode: approved ? '123456' : '', transactionid: '12345', avsresponse: 'N', cvvresponse: 'M', orderid: @nmi_invoice,
          type: 'sale', response_code: approved ? '100' : '202') }
      when 'void', 'refund'
        @nmi_reversals << fields
        assert_equal '12345', fields.fetch('transactionid')
        ok = @nmi_reversal_mode != :declined
        if ok
          @nmi_condition = 'canceled' if fields['type'] == 'void'
          @nmi_extra_actions += "<action><action_type>#{fields['type']}</action_type><success>1</success><amount>#{fields['amount'] || @nmi_amount}</amount></action>"
        end
        # :timeout = NMI applied it but the response was lost.
        raise Net::ReadTimeout if @nmi_reversal_mode == :timeout
        { status: 200, body: URI.encode_www_form(response: ok ? '1' : '3', responsetext: ok ? 'SUCCESS' : 'Refund Amount may not exceed the transaction balance',
          transactionid: ok ? (fields['type'] == 'void' ? '12345' : '12399') : '', type: fields['type'], response_code: ok ? '100' : '300') }
      else
        flunk "Unexpected NMI transaction type #{fields['type']}"
      end
    end
    stub_request(:post, Pos::NmiGateway.query_url(environment)).to_return do |request|
      fields = URI.decode_www_form(request.body).to_h
      assert_equal 'sandbox-private-fixture', fields.fetch('security_key')
      body = if fields['report_type'] == 'profile'
        "<nm_response><merchant><company>#{@nmi_company}</company></merchant></nm_response>"
      else
        assert_equal @nmi_invoice, fields['order_id'] if fields['order_id']
        @nmi_xml_override || nmi_transaction_xml
      end
      { status: 200, body: body }
    end
  end

  def nmi_transaction_xml
    "<nm_response><transaction><transaction_id>12345</transaction_id><transaction_type>cc</transaction_type>" \
      "<condition>#{@nmi_condition}</condition><order_id>#{@nmi_order_override || @nmi_invoice}</order_id>" \
      "<authorization_code>123456</authorization_code><cc_number>4xxxxxxxxxxx1111</cc_number><cc_type>visa</cc_type>" \
      "<currency>#{@nmi_currency}</currency><action><action_type>sale</action_type><success>1</success>" \
      "<amount>#{@nmi_amount}</amount><date>20261102120000</date><response_code>100</response_code></action>#{@nmi_extra_actions}</transaction></nm_response>"
  end

  def nmi_credentials
    { security_key: 'sandbox-private-fixture', tokenization_key: 'sandbox-public-fixture', merchant_company: 'Sandbox Company' }.to_json
  end
end
