# frozen_string_literal: true

require 'test_helper'
require_relative '../support/ask_rupert_helper'

# The WebMCP endpoints behave like any other signed-in page: session, CSRF,
# employee restriction, permissions and the activity log all apply.
class WebMcpTest < ActionDispatch::IntegrationTest
  include AskRupertHelper

  setup do
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
    @tenant = tenants(:default_tenant)
    @admin = users(:regular_user)
  end

  teardown do
    Current.reset
    ENV.delete('RUPERT_WEBMCP')
    Rack::Attack.cache.store.clear if defined?(Rack::Attack)
  end

  def json = response.parsed_body

  def call_tool(name, arguments = {}, **extra)
    post webmcp_tool_path(name), params: { arguments: arguments }.merge(extra), as: :json
  end

  def webmcp_logs
    Current.tenant = @tenant
    ActivityLog.where(action: 'webmcp_tool_call').order(:id)
  end

  test 'signed-in pages point the browser module at this person’s tool list' do
    sign_in @admin
    get root_path
    assert_response :success
    assert_select 'script#rupert-webmcp[type="application/json"]', count: 1 do |elements|
      config = JSON.parse(elements.first.text)
      assert_equal 'app', config['mode']
      assert_equal '/webmcp/tools', config['endpoint']
      assert_equal WebMcp::Registry.key_for(@admin), config['key']
    end
  end

  test 'the public landing page registers read-only facts and links llms.txt' do
    get root_path
    assert_response :success
    assert_select 'link[rel="alternate"][href="/llms.txt"]'
    assert_select 'script[type="module"][src*="lib/webmcp"]'
    assert_select 'script#rupert-webmcp[type="application/json"]' do |elements|
      config = JSON.parse(elements.first.text)
      assert_equal 'public', config['mode']
      assert_equal 'sdolbec@rupertpos.com', config['tools'].find { |tool| tool['name'] == 'get_contact' }['result']['email']
    end
  end

  test 'llms.txt and llms-full.txt are public Markdown' do
    get '/llms.txt'
    assert_response :success
    assert_equal 'text/markdown', response.media_type
    assert response.body.start_with?('# Rupert')
    assert_includes response.body, 'sdolbec@rupertpos.com'
    assert_match(/public/, response.headers['Cache-Control'])

    get '/llms-full.txt'
    assert_response :success
    assert_includes response.body, '## Pricing (USD)'
  end

  test 'the tool list follows the person’s role' do
    sign_in person(:cashier)
    get webmcp_tools_path, as: :json
    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    names = json['tools'].pluck('name')
    assert_includes names, 'inventory_search'
    assert_not_includes names, 'sales_summary'
    assert_not_includes names, 'create_task'
    assert json['tools'].all? { |tool| tool['annotations']['readOnlyHint'] }
  end

  test 'a read tool runs as the person and is audited without its arguments' do
    sign_in @admin
    call_tool('inventory_search', { query: 'SECRET-LOOKING-QUERY' })
    assert_response :success
    assert_equal false, json['isError']
    assert json['structuredContent'].is_a?(Hash)
    log = webmcp_logs.last
    assert_match(/tool=inventory_search; outcome=ok/, log.details)
    assert_match(/confirmed=no/, log.details)
    assert_match(/args_sha256=\h{64}/, log.details)
    assert_not_includes log.details, 'SECRET-LOOKING-QUERY'
  end

  test 'a tool the role lacks is refused as if it did not exist' do
    sign_in person(:cashier)
    call_tool('sales_summary', {})
    assert_response :not_found
    assert_equal true, json['isError']
    assert_equal 'unknown_tool', json['error']
  end

  test 'Ask Rupert’s page finder is available as a browser tool' do
    sign_in @admin
    call_tool('where_is', { query: 'timesheets' })
    assert_response :success
    assert_equal false, json['isError']
    assert json['structuredContent']['links'].is_a?(Array)
  end

  test 'invalid arguments come back as a tool error' do
    sign_in @admin
    call_tool('inventory_search', { per_page: 'lots' })
    assert_response :unprocessable_content
    assert_equal 'invalid_arguments', json['error']
  end

  test 'create_task needs the person’s confirmation; a dry run saves nothing' do
    sign_in @admin
    Current.tenant = @tenant
    assert_no_difference -> { Projects::Task.count } do
      call_tool('create_task', { title: 'Restock the tea shelf' })
      assert_response :precondition_required
      assert_equal 'confirmation_required', json['error']

      call_tool('create_task', { title: 'Restock the tea shelf', dry_run: true })
      assert_response :success
      assert_match(/Dry run/, json['content'].first['text'])
      assert_match(/tool=create_task; outcome=ok; .*confirmed=no; dry_run=yes/, webmcp_logs.last.details)
    end

    assert_difference -> { Projects::Task.count }, 1 do
      call_tool('create_task', { title: 'Restock the tea shelf' }, confirmed: true)
      assert_response :success
    end
    Current.tenant = @tenant
    task = Projects::Task.order(:id).last
    assert_equal 'Restock the tea shelf', task.title
    assert_includes task.description.to_s, 'Browser assistant (WebMCP)'
    assert_match(/tool=create_task; outcome=ok; .*confirmed=yes/, webmcp_logs.last.details)
  end

  test 'a reader cannot create tasks even when the page says it confirmed' do
    sign_in person(:reader)
    Current.tenant = @tenant
    assert_no_difference -> { Projects::Task.count } do
      call_tool('create_task', { title: 'Sneaky' }, confirmed: true)
    end
    assert_response :not_found
  end

  test 'staff self-service accounts get no browser tools' do
    sign_in person(:employee)
    get webmcp_tools_path, as: :json
    assert_response :forbidden
    call_tool('inventory_search', {})
    assert_response :forbidden
  end

  test 'signed out, the endpoints show nothing' do
    get webmcp_tools_path, as: :json
    assert_response :redirect
    call_tool('inventory_search', {})
    assert_response :redirect
  end

  test 'the install can switch browser tools off' do
    ENV['RUPERT_WEBMCP'] = 'off'
    sign_in @admin
    get root_path
    assert_select 'script#rupert-webmcp', count: 0
    get webmcp_tools_path, as: :json
    assert_response :forbidden
  end

  test 'a call without the page’s CSRF token is refused' do
    sign_in @admin
    # Set it on ApplicationController: another test may have given that class its own value,
    # which would hide a change made on ActionController::Base.
    old_forgery = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    call_tool('inventory_search', {})
    assert_response :unprocessable_content
    assert_equal 'csrf', json['error']
  ensure
    ApplicationController.allow_forgery_protection = old_forgery
  end
end
