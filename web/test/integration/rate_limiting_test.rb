# frozen_string_literal: true

require 'test_helper'

class RateLimitingTest < ActionDispatch::IntegrationTest
  setup do
    # Rack::Attack counts per fixed time window; a run that crossed a window
    # boundary reset the counter and the expected 429 never came. Freeze time.
    freeze_time
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
    @tenant = tenants(:default_tenant)
    @admin = User.create!(email: 'limits@example.com', password: 'password123', role: 'super_admin', tenant_id: @tenant.id, name: 'Limits')
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
    unfreeze_time
  end

  test 'secret-bearing settings endpoints are throttled per IP with a Retry-After header' do
    post login_path, params: { email: 'limits@example.com', password: 'password123' }
    limit = Rack::Attack.throttles['settings-secrets/ip'].limit
    limit.times do
      get '/settings/env.json'
      assert_response :success
    end
    get '/settings/env.json'
    assert_response :too_many_requests
    assert_match(/\A\d+\z/, response.headers['Retry-After'])
    assert_equal 'rate_limited', response.parsed_body.dig('error', 'code')
  end

  test 'password login is throttled per email before the database lockout counts failures' do
    limit = Rack::Attack.throttles['login/email'].limit
    limit.times do
      post login_path, params: { email: 'limits@example.com', password: 'wrong' }
      assert_response :unprocessable_entity
    end
    post login_path, params: { email: 'limits@example.com', password: 'wrong' }
    assert_response :too_many_requests
  end

  test 'health checks are never throttled' do
    (Rack::Attack.throttles['all/ip'].limit + 5).times { get '/up' }
    assert_response :success
  end

  test 'the API IP limit also applies to rotating and malformed bearer headers' do
    limit = Rack::Attack.throttles['api/ip'].limit
    limit.times { |i| get '/api/v1/catalog', headers: { 'Authorization' => "Bearer token#{i}" } }
    get '/api/v1/catalog', headers: { 'Authorization' => 'Malformed header' }
    assert_response :too_many_requests, 'unauthenticated calls share the per-IP bucket'

    Digest::SHA256.expects(:hexdigest).never
    get '/api/v1/catalog', headers: { 'Authorization' => 'Bearer rupert_not-a-real-token-but-shaped-like-one-000000000' }
    assert_response :too_many_requests, 'an exhausted IP bucket is checked before allocating another token bucket'
  end

  test 'the MCP endpoint has its own per-token bucket' do
    headers = { 'Authorization' => 'Bearer rupert_not-a-real-token-but-shaped-like-one-000000000', 'Content-Type' => 'application/json' }
    body = { jsonrpc: '2.0', id: 1, method: 'ping' }.to_json
    Rack::Attack.throttles['mcp/token'].limit.times do
      post '/mcp', params: body, headers: headers
      assert_response :unauthorized
    end
    post '/mcp', params: body, headers: headers
    assert_response :too_many_requests
    get '/api/v1/catalog', headers: headers
    assert_response :unauthorized, 'the REST API bucket is separate'
  end

  test 'the MCP IP limit applies even when bearer values rotate' do
    body = { jsonrpc: '2.0', id: 1, method: 'ping' }.to_json
    limit = Rack::Attack.throttles['mcp/ip'].limit
    limit.times do |i|
      post '/mcp', params: body, headers: { 'Authorization' => "Bearer token#{i}", 'Content-Type' => 'application/json' }
      assert_response :unauthorized
    end
    post '/mcp', params: body, headers: { 'Authorization' => 'Malformed', 'Content-Type' => 'application/json' }
    assert_response :too_many_requests
    Digest::SHA256.expects(:hexdigest).never
    post '/mcp', params: body, headers: { 'Authorization' => 'Bearer another-new-token', 'Content-Type' => 'application/json' }
    assert_response :too_many_requests
  end
end
