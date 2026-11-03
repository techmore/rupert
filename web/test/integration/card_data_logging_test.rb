# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ops_log_helper'

# End to end: card data sent to Rupert in any shape must not reach the log, the stored
# operations events, an error report or team chat. Rupert never asks for card data
# (hosted fields and terminals do); this proves the backstop. Public test cards only.
class CardDataLoggingTest < ActionDispatch::IntegrationTest
  include OpsLogHelper

  VISA = '4111111111111111'
  TRACK1 = "%B#{VISA}^DOE/JOHN Q^2512101000001230000?".freeze
  TRACK2 = ";#{VISA}=25121010000012300000?".freeze

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    OpsLog::Noise.reset!
    OpsEvent.delete_all
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
    @admin.update!(password: 'password123')
    Current.tenant = @tenant
  end

  teardown do
    Current.reset
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def assert_no_card_data(text)
    flat = text.to_s.delete(' -')
    refute_includes flat, VISA
    refute_includes text.to_s, 'DOE/JOHN'
    refute_includes text.to_s, '2512101'
  end

  test 'card fields under processor names never reach the request log' do
    sign_in(@admin)
    lines = capture_ops_log do
      post locations_path, params: { cardNumber: VISA, cardCode: '987', cvc: '987', pan: VISA, track1: TRACK1, track2: TRACK2,
        expirationDate: '1225', location: { name: '' } }
    end
    assert lines.any?
    assert_no_card_data(ops_raw)
    # The CVC as a logged value; a bare "987" also matches counters such as
    # "allocations":2987 and made this test flaky.
    refute_match(/[":=\s]987(?!\d)|"987"/, ops_raw.gsub(/"(?:allocations|bytes|duration_ms|db_ms|user_id)":[\d.]+/, ''))
  end

  test 'an exception carrying track data is logged and stored without it' do
    sign_in(@admin)
    HomeController.any_instance.stubs(:index).raises(RuntimeError, "reader sent #{TRACK1} and pan#{VISA}")
    original = Rails.application.env_config['action_dispatch.show_exceptions']
    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    capture_ops_log { get dashboard_path }
    assert_response :internal_server_error
    assert_includes ops_raw, 'RuntimeError'
    assert_no_card_data(ops_raw)
    assert OpsEvent.unscoped.exists?
    OpsEvent.unscoped.find_each { |row| assert_no_card_data(row.attributes.to_json) }
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original
  end

  test 'an event field or a library log line with a card number is redacted' do
    capture_ops_log do
      OpsLog.event('payment_debug', level: :warn, note: "terminal echoed #{TRACK2}", ids: ["x#{VISA}"])
      Rails.logger.warn("gateway said card#{VISA} declined")
    end
    assert_includes ops_raw, 'payment_debug'
    assert_includes ops_raw, CardData::REPLACEMENT
    assert_no_card_data(ops_raw)
    OpsEvent.unscoped.find_each { |row| assert_no_card_data(row.attributes.to_json) }
  end

  test 'a Sentry event is redacted before it leaves' do
    event = Struct.new(:request, :message, :exception).new(nil, "card #{TRACK1}", nil)
    out = OpsLog.sentry_before_send(event)
    assert_no_card_data(out.message)
  end

  test 'team chat never stores a pasted card number or track data' do
    TeamChat::Agent.any_instance.stubs(:run)
    room = TeamChat::Room.ensure_defaults!(@admin)
    message = TeamChat::Post.call(room: room, user: @admin, body: "customer card is 4111 1111 1111 1111 cvv 987, swipe #{TRACK1}").message
    stored = TeamChat::Message.unscoped.find(message.id).body
    assert_no_card_data(stored)
    refute_includes stored, '987'
    assert_includes stored, CardData::REPLACEMENT

    message.edit_body!("again: #{VISA}")
    assert_no_card_data(TeamChat::Message.unscoped.find(message.id).body)
  end
end
