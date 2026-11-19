# frozen_string_literal: true

module Pos
  # Turns a gateway reason code into short wording that is safe to show the
  # customer and cashier. Raw gateway text is never stored or displayed: it can
  # contain card data, merchant setup details or fraud signals.
  module DeclineReason
    ISSUER = 'Declined by the card issuer. Try another card or another way to pay.'
    CARD_NUMBER = 'The card number was not accepted. Check it or try another card.'
    EXPIRED = 'The card has expired. Try another card.'
    EXPIRY = 'The expiration date was not accepted. Check it and try again.'
    CVV = 'The security code (CVV) did not match. Check it and try again.'
    ADDRESS = 'The billing ZIP or address did not match the card. Check it and try again.'
    CARD_TYPE = 'This card type is not accepted here. Try another card.'
    FUNDS = 'Declined for insufficient funds. Try another card or another way to pay.'
    DUPLICATE = 'This looks like a duplicate of a payment just made. Check the receipt before trying again.'
    REVIEW = 'The payment is held for review by the processor. Do not charge again; a manager must check it.'
    SETUP = 'The card gateway refused the request because of a setup problem. Ask a manager to check checkout setup.'
    GENERIC = 'The payment was not approved. Try another card or another way to pay.'

    # Authorize.net transaction response reason codes
    # (developer.authorize.net/api/reference/responseCodes.html).
    AUTHORIZE_NET = {
      2 => ISSUER, 3 => ISSUER, 4 => ISSUER, 41 => ISSUER, 250 => ISSUER, 251 => ISSUER, 254 => ISSUER,
      5 => GENERIC, 6 => CARD_NUMBER, 37 => CARD_NUMBER, 78 => CVV, 7 => EXPIRY, 8 => EXPIRED,
      11 => DUPLICATE, 27 => ADDRESS, 127 => ADDRESS, 44 => CVV, 45 => CVV, 65 => CVV,
      17 => CARD_TYPE, 28 => CARD_TYPE, 252 => REVIEW, 253 => REVIEW,
      13 => SETUP, 103 => SETUP, 123 => SETUP, 261 => SETUP, 315 => SETUP, 316 => SETUP
    }.freeze

    # NMI response_code values (docs.nmi.com/reference/response-codes).
    NMI = {
      200 => ISSUER, 201 => ISSUER, 204 => ISSUER, 240 => ISSUER, 250 => ISSUER, 251 => ISSUER, 252 => ISSUER,
      253 => ISSUER, 260 => ISSUER, 202 => FUNDS, 203 => FUNDS, 220 => CARD_NUMBER, 221 => CARD_NUMBER,
      222 => CARD_NUMBER, 223 => EXPIRED, 224 => EXPIRY, 225 => CVV, 461 => CARD_TYPE, 430 => DUPLICATE,
      410 => SETUP, 411 => SETUP, 460 => SETUP
    }.freeze

    module_function

    def authorize_net(code) = lookup(AUTHORIZE_NET, code)

    def nmi(code) = lookup(NMI, code)

    def lookup(table, code)
      return GENERIC unless code.to_s.match?(/\A\d{1,4}\z/)

      table.fetch(code.to_i, GENERIC)
    end
  end
end
