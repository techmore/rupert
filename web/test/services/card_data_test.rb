# frozen_string_literal: true

require 'test_helper'

# CardData is the backstop that keeps card numbers, track data and security codes out of
# logs, reports, chat and AI prompts. Rupert never accepts card data; these are the shapes
# it would take if a person or a library wrote it anyway. All numbers are public test cards.
class CardDataTest < ActiveSupport::TestCase
  VISA = '4111111111111111'
  MASTERCARD = '5555555555554444'
  AMEX = '378282246310005'
  DISCOVER = '6011111111111117'
  TRACK1 = "%B#{VISA}^DOE/JOHN Q^2512101000001230000?".freeze
  TRACK2 = ";#{VISA}=25121010000012300000?".freeze

  test 'removes card numbers of every major brand, plain or grouped' do
    [VISA, MASTERCARD, AMEX, DISCOVER, '4111 1111 1111 1111', '5555-5555-5555-4444', '3782 822463 10005'].each do |number|
      out = CardData.redact("paid with #{number} today")
      assert_equal "paid with #{CardData::REPLACEMENT} today", out, number
    end
  end

  test 'removes track 1 with the cardholder name, track 2 and EMV track 2 equivalent data' do
    [TRACK1, TRACK2, "#{VISA}D25121010000012300000"].each do |track|
      out = CardData.redact("swipe: #{track} end")
      assert_equal "swipe: #{CardData::REPLACEMENT} end", out, track
      refute_includes out, 'DOE'
    end
  end

  test 'finds a card number touching letters, a leading quantity or a trailing expiry date' do
    assert_equal "pan#{CardData::REPLACEMENT}", CardData.redact("pan#{VISA}")
    assert_equal "qty #{CardData::REPLACEMENT} x", CardData.redact('qty 2 4111 1111 1111 1111 x')
    assert_equal CardData::REPLACEMENT, CardData.redact("#{VISA}1225")
    assert_equal %({"note":"#{CardData::REPLACEMENT}"}), CardData.redact(%({"note":"#{VISA}"}))
  end

  test 'removes labelled security codes in ordinary sentences' do
    out = CardData.redact('cvv: 123, CVC 9876 and security code 456')
    refute_match(/123|9876|456/, out)
    assert_includes out, CardData::CODE_REPLACEMENT
  end

  test 'leaves ordinary numbers alone' do
    [
      '4111111111111112',                  # fails Luhn
      'USPS 9400 1118 9922 3333 4444 55',  # parcel tracking id
      'UPC 012345678905',                  # 12-digit barcode
      'EAN 0012345678905',                 # 13 digits starting with 0
      'order 1234567890123',               # fails Luhn
      'call 267-555-0100',                 # phone number
      'total $1,234.56 on 2026-11-02',
      'code 1234 for the door'             # not a card security code label
    ].each { |text| assert_equal text, CardData.redact(text), text }
  end

  test 'contains? reports card data and handles non-strings' do
    assert CardData.contains?("x #{VISA}")
    refute CardData.contains?('nothing here 12345')
    refute CardData.contains?(nil)
    assert_nil CardData.redact(nil)
  end

  test 'the log, bug report and AI prompt redactors all remove card data' do
    [TRACK1, "pan#{VISA}", '4111 1111 1111 1111'].each do |text|
      [OpsLog.safe_text(text, strict: false), FeedbackSanitizer.scrub_text(text), AskRupert::Redactor.clean(text),
        AskRupert::Redactor.personal(text)].each do |out|
        refute_includes out.delete(' '), VISA, "#{text} -> #{out}"
        refute_includes out, 'DOE'
      end
    end
    refute_includes FeedbackSanitizer.scrub_text('my cvc=987 please'), '987'
  end

  test 'structured log fields and exception reports never carry a card number' do
    assert_equal({ note: "x #{CardData::REPLACEMENT}" }, OpsLog.clean(note: "x #{VISA}"))
    assert_equal({ list: [CardData::REPLACEMENT] }, OpsLog.clean(list: [VISA]))
    error = RuntimeError.new("declined #{TRACK1}")
    refute_includes OpsLog.error_fields(error)[:error_message], '4111'
  end

  test 'the request-log parameter filter hides card fields under processor and terminal names' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = { 'cardNumber' => VISA, 'cardCode' => '123', 'cvc' => '123', 'pan' => VISA, 'track2' => TRACK2,
      'track_data' => TRACK1, 'expirationDate' => '1225', 'security_code' => '123', 'company' => 'Herbal', 'tracking_ok' => 'y' }
    filtered = filter.filter(params)
    %w[cardNumber cardCode cvc pan track2 track_data expirationDate security_code].each do |key|
      assert_equal '[FILTERED]', filtered[key], key
    end
    assert_equal 'Herbal', filtered['company']
  end
end
