# frozen_string_literal: true

require 'test_helper'

# Pos::DeviceReader::RequestScreen: random identifiers are never mistaken for
# card data, and nothing else escapes the scan.
class DeviceReaderRequestScreenTest < ActiveSupport::TestCase
  Screen = Pos::DeviceReader::RequestScreen
  VISA = '4111111111111111'
  TOKEN = '8a7839b2c1c3d4a6c0735770c7fb31140710943470ee46f189e5b566cf4e81da' # CardData.contains? is true
  DEVICE = '8700d2c8-4bae-d459-7250-12826382d0b4' # CardData.contains? is true
  APPROVED = { 'status' => 'approved', 'amount_cents' => 1166, 'last_four' => '1111', 'auth_code' => 'A1B2C3' }.freeze

  def status(action, body, query = {}) = Screen.call(action, body, query).status

  test 'no random token or install identifier is ever refused' do
    random = Random.new(20_261_118)
    hex = ->(length) { Array.new(length) { random.rand(16).to_s(16) }.join }
    tripped = 0
    5_000.times do
      token = hex.call(64)
      raw = hex.call(32)
      device = [raw[0, 8], raw[8, 4], raw[12, 4], raw[16, 4], raw[20, 12]].join('-')
      device = device.upcase if random.rand(2).zero?
      tripped += 1 if CardData.contains?(token) || CardData.contains?(device)
      assert_equal :ok, status('start', { 'token' => token, 'device_id' => device }), [token, device].inspect
      assert_equal :ok, status('cancel', { 'token' => token, 'device_id' => device }), [token, device].inspect
      assert_equal :ok, status('result', { 'token' => token, 'device_id' => device, 'result' => APPROVED }), [token, device].inspect
    end
    assert_operator tripped, :>, 10, 'the sample includes values the detector would have refused'
  end

  test 'an identifier is exempt only as itself, in its place, in its exact format' do
    ok = { 'token' => TOKEN, 'device_id' => DEVICE }
    assert_equal :ok, status('start', ok)
    assert_equal :card_data, status('create', { 'token' => TOKEN }), 'open takes no token'
    assert_equal :card_data, status('start', ok.merge('token' => TOKEN.upcase)), 'not the token format'
    assert_equal :card_data, status('start', ok.merge('token' => "#{TOKEN}0"))
    assert_equal :card_data, status('start', ok.merge('token' => " #{TOKEN}"))
    assert_equal :card_data, status('start', ok.merge('token' => "#{TOKEN}\n"))
    assert_equal :card_data, status('start', ok.merge('token' => [TOKEN]))
    assert_equal :card_data, status('start', ok.merge('device_id' => DEVICE.delete('-')))
    assert_equal :card_data, status('start', ok.merge('device_id' => "#{DEVICE}\n"))
    assert_equal :card_data, status('start', ok.merge('device_id' => { 'id' => DEVICE }))
    assert_equal :card_data, status('start', ok.merge('device_id' => TOKEN, 'token' => DEVICE)), 'each format belongs to its own field'
    assert_equal :card_data, status('start', ok.merge('session_token' => TOKEN))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('token' => TOKEN)))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('device_id' => DEVICE)))
    assert_equal :card_data, status('start', ok, { 'token' => TOKEN }), 'never in the query string'
    assert_equal :card_data, status('start', ok.merge(TOKEN => 'x')), 'never as a key'
  end

  test 'card data is refused everywhere it was refused before' do
    ok = { 'token' => TOKEN, 'device_id' => DEVICE }
    assert_equal :card_data, status('start', ok.merge('token' => VISA))
    assert_equal :card_data, status('start', ok.merge('device_id' => VISA))
    assert_equal :card_data, status('start', ok.merge('pan' => VISA))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('auth_code' => VISA)))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('amount_cents' => VISA.to_i)))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('emv' => { 'tag57' => "#{VISA}D2512101" })))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('provider_reference' => '4111 1111 1111 1111')))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('provider_reference' => ";#{VISA}=2512101?")))
    assert_equal :card_data, status('result', ok.merge('result' => APPROVED.merge('provider_reference' => [VISA])))
    assert_equal :card_data, status('result', ok.merge('result' => [VISA]))
    assert_equal :card_data, status('cancel', ok, { 'note' => VISA })
    assert_equal :unknown_field, status('start', ok.merge('amount_cents' => 1))
    assert_equal :unknown_field, status('start', ok, { 'x' => '1' })
    assert_equal :card_data, status('nonsense', ok), 'an unknown action exempts nothing'
    assert_equal :unknown_field, status('nonsense', { 'device_id' => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' })
  end

  test 'a well-formed provider reference or approval code that looks card-shaped is dropped, never kept' do
    body = { 'token' => TOKEN, 'device_id' => DEVICE, 'result' => APPROVED.merge('provider_reference' => VISA) }
    verdict = Screen.call('result', body)
    assert_equal [:ok, ['provider_reference']], [verdict.status, verdict.dropped]
    assert_equal APPROVED, verdict.body['result']
    refute_includes verdict.body.to_json, VISA
    code = Screen.call('result', body.merge('result' => APPROVED.merge('auth_code' => 'CVC123')))
    assert CardData.contains?('CVC123'), 'an approval code can read as a labelled security code'
    assert_equal [:ok, ['auth_code'], APPROVED.except('auth_code')], [code.status, code.dropped, code.body['result']]
    kept = Screen.call('result', body.merge('result' => APPROVED.merge('provider_reference' => 'FAKE-0A1B2C')))
    assert_equal [:ok, [], 'FAKE-0A1B2C'], [kept.status, kept.dropped, kept.body.dig('result', 'provider_reference')]
  end
end
