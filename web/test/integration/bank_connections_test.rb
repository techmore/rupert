# frozen_string_literal: true

require 'test_helper'

class BankConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @connection = BankConnection.create!(credentials_json: { client_id: 'client-private', secret: 'secret-private' }.to_json)
    post login_path, params: { email: 'admin@example.com', password: 'password' }
  end
  teardown { Current.reset }

  def begin_link
    stub_request(:post, 'https://sandbox.plaid.com/link/token/create').to_return(status: 200, body: { link_token: 'link-private' }.to_json)
    post link_token_bank_connection_path, as: :json
    assert_response :success
  end

  def stub_item(access: 'access-private', name: 'Wells Fargo', item: 'item-1')
    stub_request(:post, 'https://sandbox.plaid.com/item/get').with { |request| JSON.parse(request.body)['access_token'] == access }
      .to_return(status: 200, body: { item: { item_id: item, institution_id: 'wells-test' } }.to_json)
    stub_request(:post, 'https://sandbox.plaid.com/institutions/get_by_id').to_return(status: 200, body: { institution: { name: name } }.to_json)
  end

  def stub_exchange
    stub_request(:post, 'https://sandbox.plaid.com/item/public_token/exchange')
      .to_return(status: 200, body: { access_token: 'access-private', item_id: 'item-1' }.to_json)
  end

  test 'finance UI renders safe setup controls without returning saved secrets' do
    get bank_connection_path
    assert_response :success
    assert_includes response.body, 'Connect Wells Fargo'
    assert_includes response.body, 'Sandbox uses test accounts'
    assert_includes response.body, 'hourly transaction sync'
    assert_not_includes response.body, 'client-private'
    assert_not_includes response.body, 'secret-private'
    assert_equal 'private, no-store', response.headers['Cache-Control']
    assert_select 'nav[aria-label="Finance workspace"] a[href=?][aria-current="page"]', bank_connection_path
    get bank_statements_path
    assert_select 'a[href=?]', bank_connection_path
  end

  test 'credentials stay encrypted and blank fields preserve them only within an environment' do
    patch bank_connection_path, params: { bank_connection: { environment: 'sandbox', client_id: '', secret: '' } }
    assert_redirected_to bank_connection_path
    assert_equal 'secret-private', @connection.reload.credentials['secret']
    patch bank_connection_path, params: { bank_connection: { environment: 'production', client_id: '', secret: '' } }
    assert_equal({}, @connection.reload.credentials)
    patch bank_connection_path, params: { bank_connection: { environment: 'production', client_id: 'new-client', secret: 'new-secret' } }
    raw = ActiveRecord::Base.connection.select_value('SELECT credentials_json FROM bank_connections LIMIT 1')
    assert_not_includes raw, 'new-secret'
    assert @connection.reload.configured?
    assert_not_requested(:post, /plaid\.com/)
  end

  test 'Link exchange verifies the actual institution and queues the first sync' do
    begin_link
    stub_exchange
    stub_item
    assert_enqueued_with(job: BankFeedSyncJob, args: [@tenant.id]) do
      post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    end
    assert_response :success
    assert_equal bank_connection_path, response.parsed_body['redirect_url']
    assert @connection.reload.connected?
    assert @connection.sync_enabled?
    assert_equal 'item-1', @connection.item_id
    post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    assert_response :unprocessable_entity
    assert_equal 'access-private', @connection.reload.access_token
  end

  test 'a different bank is rejected and the exchanged item is revoked' do
    begin_link
    stub_exchange
    stub_item(name: 'Another Bank')
    removal = stub_request(:post, 'https://sandbox.plaid.com/item/remove').to_return(status: 200, body: '{}')
    post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'WRONG_INSTITUTION'
    assert_not @connection.reload.connected?
    assert_requested removal
  end

  test 'OAuth resume returns only the current user flow and expired flows cannot exchange' do
    begin_link
    get bank_connection_path(oauth_state_id: 'state-private')
    assert_response :success
    assert_includes response.body, 'data-bank-link-resume-value="true"'
    post resume_bank_connection_path, as: :json
    assert_equal 'link-private', response.parsed_body['link_token']
    travel 31.minutes do
      post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
      assert_response :unprocessable_entity
      assert_includes response.parsed_body['error'], 'LINK_EXPIRED'
    end
    assert_not_requested(:post, 'https://sandbox.plaid.com/item/public_token/exchange')
  end

  test 'reconnect uses update mode and preserves the cursor and old lines' do
    @connection.update!(access_token: 'access-private', item_id: 'item-1', cursor: 'cursor-private', sync_enabled: true)
    begin_link
    assert_requested(:post, 'https://sandbox.plaid.com/link/token/create') do |request|
      body = JSON.parse(request.body)
      body['access_token'] == 'access-private' && !body.key?('products') && body['redirect_uri'].end_with?('/bank_connection')
    end
    stub_item
    post exchange_bank_connection_path, as: :json
    assert_response :success
    assert_equal 'cursor-private', @connection.reload.cursor
    assert_not_requested(:post, 'https://sandbox.plaid.com/item/public_token/exchange')
  end

  test 'disconnect revokes the item before clearing access and disables future syncs' do
    @connection.update!(access_token: 'access-private', item_id: 'item-1', cursor: 'cursor-private', sync_enabled: true)
    removal = stub_request(:post, 'https://sandbox.plaid.com/item/remove').to_return(status: 200, body: '{}')
    delete disconnect_bank_connection_path
    assert_redirected_to bank_connection_path
    assert_requested removal
    assert_not @connection.reload.connected?
    assert_not @connection.sync_enabled?
    assert_nil @connection.cursor
    assert_no_enqueued_jobs(only: BankFeedSyncJob) { post sync_bank_connection_path }
  end

  test 'failed revocation retains access so it can be retried' do
    @connection.update!(access_token: 'access-private', item_id: 'item-1', sync_enabled: true)
    stub_request(:post, 'https://sandbox.plaid.com/item/remove').to_return(status: 500, body: { error_code: 'INTERNAL_SERVER_ERROR' }.to_json)
    delete disconnect_bank_connection_path
    assert_redirected_to bank_connection_path
    assert @connection.reload.connected?
    assert_not @connection.sync_enabled?
  end

  test 'connected credentials cannot be replaced' do
    @connection.update!(access_token: 'access-private', item_id: 'item-1', sync_enabled: true)
    patch bank_connection_path, params: { bank_connection: { environment: 'production', client_id: 'other', secret: 'other' } }
    assert_equal 'sandbox', @connection.reload.environment
    assert_equal 'secret-private', @connection.credentials['secret']
  end

  test 'roles without finance access cannot view or mutate bank access' do
    users(:regular_user).update!(role: 'reporting')
    get bank_connection_path
    assert_redirected_to root_path
    post link_token_bank_connection_path, as: :json
    assert_response :redirect
    post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    delete disconnect_bank_connection_path
    patch bank_connection_path, params: { bank_connection: { environment: 'production', client_id: 'other', secret: 'other' } }
    assert_equal 'sandbox', @connection.reload.environment
    assert_not @connection.connected?
    assert_not_requested(:post, /plaid\.com/)
  end

  test 'production Link requires HTTPS' do
    @connection.update!(environment: 'production')
    post link_token_bank_connection_path, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'HTTPS_REQUIRED'
    assert_not_requested(:post, /plaid\.com/)
  end

  test 'a Link flow cannot be exchanged after the user changes workspaces' do
    begin_link
    other = Tenant.create!(name: 'Other bank workspace', subdomain: 'other-bank-workspace', status: 'active')
    users(:regular_user).update!(tenant: other)
    post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'LINK_EXPIRED'
    assert_not_requested(:post, 'https://sandbox.plaid.com/item/public_token/exchange')
    assert_not @connection.reload.connected?
  end

  test 'disconnect invalidates a pending connection in another browser session' do
    begin_link
    pending_cookie = cookies.to_hash
    delete disconnect_bank_connection_path
    pending_cookie.each { |key, value| cookies[key] = value }
    post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'LINK_EXPIRED'
    assert_not @connection.reload.connected?
    assert_not_requested(:post, 'https://sandbox.plaid.com/item/public_token/exchange')
  end

  test 'failed revocation invalidates an open update-mode flow in another session' do
    @connection.update!(access_token: 'access-private', item_id: 'item-1', sync_enabled: true)
    begin_link
    pending_cookie = cookies.to_hash
    stub_request(:post, 'https://sandbox.plaid.com/item/remove').to_return(status: 500, body: { error_code: 'INTERNAL_SERVER_ERROR' }.to_json)
    delete disconnect_bank_connection_path
    pending_cookie.each { |key, value| cookies[key] = value }
    post exchange_bank_connection_path, as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'LINK_EXPIRED'
    assert_not @connection.reload.sync_enabled?
    assert_not_requested(:post, 'https://sandbox.plaid.com/item/get')
  end

  test 'changing credentials invalidates an open connect flow in another session' do
    begin_link
    pending_cookie = cookies.to_hash
    patch bank_connection_path, params: { bank_connection: { environment: 'sandbox', client_id: 'replacement', secret: 'replacement' } }
    pending_cookie.each { |key, value| cookies[key] = value }
    post exchange_bank_connection_path, params: { public_token: 'public-private' }, as: :json
    assert_response :unprocessable_entity
    assert_not_requested(:post, 'https://sandbox.plaid.com/item/public_token/exchange')
  end
end
