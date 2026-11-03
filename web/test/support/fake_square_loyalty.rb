# frozen_string_literal: true

# Recorded-shape fake of Square's Loyalty read endpoints (Square API 2026-09-16
# OpenAPI shapes), served through WebMock. Synthetic data only. Any request to an
# endpoint not stubbed here, including every Loyalty write, fails the test.
module FakeSquareLoyalty
  BASE = 'https://connect.squareup.com'
  PROGRAM_ID = 'f1d6f3b0-5a2c-4c8e-9f37-0d5e2b6a9c11'

  def fake_program(overrides = {})
    {
      'id' => PROGRAM_ID, 'status' => 'ACTIVE',
      'reward_tiers' => [
        { 'id' => 'tier-small', 'points' => 50, 'name' => '$5 off', 'created_at' => '2024-01-02T10:00:00Z',
          'pricing_rule_reference' => { 'object_id' => 'PRICING-1', 'catalog_version' => 1 } },
        { 'id' => 'tier-big', 'points' => 150, 'name' => '$20 off', 'created_at' => '2024-01-02T10:00:00Z',
          'pricing_rule_reference' => { 'object_id' => 'PRICING-2', 'catalog_version' => 1 } }
      ],
      'expiration_policy' => { 'expiration_duration' => 'P12M' },
      'terminology' => { 'one' => 'Leaf', 'other' => 'Leaves' },
      'location_ids' => ['LOC-1'],
      'created_at' => '2024-01-02T10:00:00Z', 'updated_at' => '2026-10-01T10:00:00Z',
      'accrual_rules' => [{ 'accrual_type' => 'SPEND', 'points' => 1, 'spend_data' => { 'amount_money' => { 'amount' => 100, 'currency' => 'USD' }, 'tax_mode' => 'BEFORE_TAX' } }]
    }.merge(overrides)
  end

  def fake_account(id, customer_id:, balance:, lifetime: balance, phone: '+15555550123')
    { 'id' => id, 'program_id' => PROGRAM_ID, 'balance' => balance, 'lifetime_points' => lifetime, 'customer_id' => customer_id,
      'enrolled_at' => '2025-03-04T15:00:00Z', 'created_at' => '2025-03-04T15:00:00Z', 'updated_at' => '2026-10-30T15:00:00Z',
      'mapping' => { 'id' => "map-#{id}", 'created_at' => '2025-03-04T15:00:00Z', 'phone_number' => phone },
      'expiring_point_deadlines' => [{ 'points' => 20, 'expires_at' => '2027-03-01T00:00:00Z' }] }
  end

  def fake_event(id, account:, type:, at:, points: nil, order_id: nil, reason: nil)
    key = type == 'OTHER' ? 'other_event' : type.downcase
    detail = { 'loyalty_program_id' => PROGRAM_ID }
    detail['points'] = points unless points.nil?
    detail['order_id'] = order_id if order_id
    detail['reason'] = reason if reason
    detail['reward_id'] = "reward-#{id}" if type.include?('REWARD')
    { 'id' => id, 'type' => type, 'created_at' => at, 'loyalty_account_id' => account, 'location_id' => 'LOC-1', 'source' => 'SQUARE', key => detail }
  end

  # Stubs every read the sync makes. events: pages of ledger events, newest first; the
  # created_at filter is applied first, then results are paged like Square does.
  # Returns the stubs so a test can assert on them.
  def stub_square_loyalty(program: fake_program, accounts: [], events: [[]], promotions: [], scopes: %w[CUSTOMERS_READ LOYALTY_READ], merchant_id: 'MERCHANT-1')
    stubs = {}
    stubs[:token] = stub_request(:post, "#{BASE}/oauth2/token/status")
                    .to_return(status: 200, body: { scopes: scopes, merchant_id: merchant_id, client_id: 'sq0idp-fake' }.compact.to_json)
    not_found = { status: 404, body: { errors: [{ category: 'INVALID_REQUEST_ERROR', code: 'NOT_FOUND' }] }.to_json }
    program_response = program ? { status: 200, body: { program: program }.to_json } : not_found
    stubs[:program] = stub_request(:get, "#{BASE}/v2/loyalty/programs/main").to_return(program_response)
    stubs[:promotions] = stub_request(:get, "#{BASE}/v2/loyalty/programs/#{PROGRAM_ID}/promotions?limit=30")
                         .to_return(status: 200, body: { loyalty_promotions: promotions }.to_json)
    stubs[:accounts] = stub_request(:post, "#{BASE}/v2/loyalty/accounts/search")
                       .with(body: { limit: 200 }.to_json).to_return(status: 200, body: { loyalty_accounts: accounts }.to_json)
    all_events = events.flatten
    page_size = events.map(&:size).max.to_i.clamp(1, 30)
    stubs[:events] = stub_request(:post, "#{BASE}/v2/loyalty/events/search").to_return do |request|
      body = JSON.parse(request.body)
      from = body.dig('query', 'filter', 'date_time_filter', 'created_at', 'start_at')
      to = body.dig('query', 'filter', 'date_time_filter', 'created_at', 'end_at')
      matching = all_events.select { |event| (!from || event['created_at'] >= from) && (!to || event['created_at'] < to) }
      pages = matching.each_slice(page_size).to_a
      index = body['cursor'] ? body['cursor'].delete_prefix('page-').to_i : 0
      cursor = index + 1 < pages.size ? "page-#{index + 1}" : nil
      { status: 200, body: { events: pages.fetch(index, []), cursor: cursor }.compact.to_json }
    end
    stubs
  end

  def square_loyalty_write_paths
    %r{/v2/loyalty/(accounts(/[^/]+/(accumulate|adjust))?$|rewards|programs/[^/]+/(calculate|promotions/[^/]+/cancel))}
  end
end
