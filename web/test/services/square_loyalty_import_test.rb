# frozen_string_literal: true

require 'test_helper'
require_relative '../support/fake_square_loyalty'

class SquareLoyaltyImportTest < ActiveSupport::TestCase
  include FakeSquareLoyalty

  setup do
    Current.tenant = tenants(:default_tenant)
    Current.user = users(:regular_user)
    SquareClient.stubs(:token).returns('synthetic-loyalty-token')
    SquareClient.stubs(:environment).returns('production')
    @customer = Core::Customer.create!(source: 'square', external_id: 'SQCUST-1', first_name: 'Mira', last_name: 'Leaf')
    @accounts = [fake_account('acct-1', customer_id: 'SQCUST-1', balance: 60, lifetime: 210), fake_account('acct-2', customer_id: 'SQCUST-UNKNOWN', balance: 5)]
    @events = [[
      fake_event('ev-3', account: 'acct-1', type: 'CREATE_REWARD', at: '2026-10-30T15:05:00Z', points: -50),
      fake_event('ev-2', account: 'acct-1', type: 'ACCUMULATE_POINTS', at: '2026-10-30T15:00:00Z', points: 12, order_id: 'ORDER-1')
    ], [
      fake_event('ev-1', account: 'acct-2', type: 'EXPIRE_POINTS', at: '2026-09-01T00:00:00Z', points: 7),
      fake_event('ev-0', account: 'acct-2', type: 'ADJUST_POINTS', at: '2026-08-01T00:00:00Z', points: -3, reason: 'Goodwill')
    ]]
  end

  teardown { Current.reset }

  test 'apply mirrors program, tiers, members and ledger, and a re-run creates no duplicates' do
    stubs = stub_square_loyalty(accounts: @accounts, events: @events)
    result = SquareLoyaltyImport.new.call(apply: true)

    assert_equal 2, result[:members]
    assert_equal 4, result[:new_events]
    assert result[:history_complete]
    program = SquareLoyaltyProgram.current
    assert program.active?
    assert_equal 'Leaves', program.point_word(2)
    assert_equal 12, program.expiration_months
    assert_equal [50, 150], program.reward_tiers.current.order(:points).pluck(:points)
    account = SquareLoyaltyAccount.find_by(external_id: 'acct-1')
    assert_equal [60, 210], [account.balance, account.lifetime_points]
    assert_equal @customer, account.customer
    assert_equal '•••• 0123', account.phone_hint
    assert_equal ['$5 off'], account.redeemable_tiers(program.reward_tiers.current.to_a).map(&:name)
    assert_nil SquareLoyaltyAccount.find_by(external_id: 'acct-2').customer
    changes = SquareLoyaltyEvent.order(:occurred_at).pluck(:external_id, :points_change)
    assert_equal [['ev-0', -3], ['ev-1', -7], ['ev-2', 12], ['ev-3', -50]], changes
    assert_equal 'ORDER-1', SquareLoyaltyEvent.find_by(external_id: 'ev-2').order_id
    assert_equal 'Goodwill', SquareLoyaltyEvent.find_by(external_id: 'ev-0').reason
    state = SquareLoyaltySync.state
    assert_equal 'MERCHANT-1', state['merchant_id']
    assert_equal 'granted', state['scope']
    assert_empty state['pending_windows']

    assert_no_difference ['SquareLoyaltyAccount.count', 'SquareLoyaltyEvent.count', 'SquareLoyaltyRewardTier.count', 'SquareLoyaltyProgram.count'] do
      second = SquareLoyaltyImport.new.call(apply: true)
      assert_equal 0, second[:new_events]
    end
    # The second run only reads the ledger from the last complete read (less a day of overlap).
    assert_requested(:post, "#{FakeSquareLoyalty::BASE}/v2/loyalty/events/search", times: 1) { |req| JSON.parse(req.body).dig('query', 'filter', 'date_time_filter', 'created_at', 'start_at') }
    assert_requested stubs[:token], times: 2
    assert_not_requested :post, square_loyalty_write_paths
    assert_not_requested :put, /squareup/
    assert_not_requested :delete, /squareup/
  end

  test 'members missing from a complete read are kept and marked, balances update in place' do
    stub_square_loyalty(accounts: @accounts, events: @events)
    SquareLoyaltyImport.new.call(apply: true)
    WebMock.reset!
    stub_square_loyalty(accounts: [fake_account('acct-1', customer_id: 'SQCUST-1', balance: 10, lifetime: 260)], events: [[]],
      program: fake_program('reward_tiers' => [fake_program['reward_tiers'].first]))
    SquareLoyaltyImport.new.call(apply: true)

    assert_equal 10, SquareLoyaltyAccount.find_by(external_id: 'acct-1').balance
    refute SquareLoyaltyAccount.find_by(external_id: 'acct-2').source_present
    assert_equal ['tier-small'], SquareLoyaltyRewardTier.current.pluck(:external_id)
    assert_equal 4, SquareLoyaltyEvent.count
  end

  test 'dry run reads but stores nothing' do
    stub_square_loyalty(accounts: @accounts, events: @events)
    assert_no_difference ['SquareLoyaltyAccount.count', 'SquareLoyaltyEvent.count', 'SquareLoyaltyProgram.count', 'Setting.count'] do
      result = SquareLoyaltyImport.new.call
      assert result[:dry_run]
      assert_equal 1, result[:linked_customers]
      assert_equal '2026-10-30T15:05:00Z', result[:newest_event_at]
    end
  end

  test 'a missing LOYALTY_READ scope stops before any loyalty read and says what to grant' do
    stubs = stub_square_loyalty(accounts: @accounts, events: @events, scopes: %w[CUSTOMERS_READ TIMECARDS_READ])
    error = assert_raises(SquareLoyaltyReader::MissingScope) { SquareLoyaltyImport.new.call(apply: true) }
    assert_includes error.message, 'LOYALTY_READ'
    assert_equal 'entitlement', SyncFailure.category(error)
    assert_not_requested stubs[:program]
    assert_equal 0, SquareLoyaltyAccount.count
  end

  test 'a 403 from Square when the token reports no scopes is reported as the missing permission' do
    stub_square_loyalty(scopes: nil)
    stub_request(:get, "#{FakeSquareLoyalty::BASE}/v2/loyalty/programs/main")
      .to_return(status: 403, body: { errors: [{ category: 'AUTHENTICATION_ERROR', code: 'INSUFFICIENT_SCOPES' }] }.to_json)
    assert_raises(SquareLoyaltyReader::MissingScope) { SquareLoyaltyImport.new.call(apply: true) }
  end

  test 'no loyalty program is a successful empty read' do
    stub_square_loyalty(program: nil)
    result = SquareLoyaltyImport.new.call(apply: true)
    assert_nil result[:program]
    assert SquareLoyaltySync.state['last_success_at'].present?
  end

  test 'a different Square account than the stored mirror is refused' do
    stub_square_loyalty(accounts: @accounts, events: @events)
    SquareLoyaltyImport.new.call(apply: true)
    WebMock.reset!
    stub_square_loyalty(accounts: [fake_account('acct-9', customer_id: nil, balance: 1)], merchant_id: 'MERCHANT-OTHER')
    error = assert_raises(SquareLoyaltyReader::Error) { SquareLoyaltyImport.new.call(apply: true) }
    assert_equal 'identity', SyncFailure.category(error)
    assert_nil SquareLoyaltyAccount.find_by(external_id: 'acct-9')
    assert SquareLoyaltyAccount.find_by(external_id: 'acct-2').source_present
  end

  test 'repeated members or a repeated cursor publish nothing' do
    stub_square_loyalty(accounts: [@accounts.first, @accounts.first])
    assert_raises(SquareLoyaltyReader::Error) { SquareLoyaltyImport.new.call(apply: true) }
    assert_equal 0, SquareLoyaltyAccount.count

    WebMock.reset!
    stub_square_loyalty
    stub_request(:post, "#{FakeSquareLoyalty::BASE}/v2/loyalty/accounts/search")
      .to_return(status: 200, body: { loyalty_accounts: [@accounts.first], cursor: 'same' }.to_json)
    assert_raises(SquareLoyaltyReader::Error) { SquareLoyaltyImport.new.call(apply: true) }
    assert_equal 0, SquareLoyaltyAccount.count
  end

  test 'a ledger read that runs out of time keeps what it stored and resumes the older part next run' do
    stub_square_loyalty(accounts: @accounts, events: @events)
    reader = SquareLoyaltyReader.new
    # Time runs out after one ledger page: the first read stops early, the rest wait.
    calls = 0
    reader.define_singleton_method(:each_event_page) do |**options, &block|
      calls += 1
      next [:partial, nil] if calls > 1

      super(**options, max_pages: 1, &block)
    end
    first = SquareLoyaltyImport.new(reader: reader).call(apply: true)
    refute first[:history_complete]
    assert_equal %w[ev-2 ev-3], SquareLoyaltyEvent.order(:external_id).pluck(:external_id)
    window = SquareLoyaltySync.state['pending_windows'].sole
    assert_nil window['start_at']

    second = SquareLoyaltyImport.new.call(apply: true)
    assert second[:history_complete]
    assert_equal %w[ev-0 ev-1 ev-2 ev-3], SquareLoyaltyEvent.order(:external_id).pluck(:external_id)
    assert_empty SquareLoyaltySync.state['pending_windows']
  end

  test 'only authorized staff can run the import' do
    reader = User.create!(tenant: Current.tenant, email: 'loyalty-reader@example.test', password: 'password123', role: 'reader')
    stubs = stub_square_loyalty
    assert_raises(Pundit::NotAuthorizedError) { SquareLoyaltyImport.new(actor: reader).call(apply: true) }
    assert_not_requested stubs[:token]
  end
end
