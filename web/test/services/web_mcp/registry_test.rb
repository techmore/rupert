# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/ask_rupert_helper'

# WebMCP's browser tools come from the shared registries (Mcp::Registry and Ask Rupert's
# lookups), are offered per person by their current permissions, and never include
# payments, refunds, customers, accounts, settings, backups, keys or exports.
class WebMcpRegistryTest < ActiveSupport::TestCase
  include AskRupertHelper

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
  end

  teardown { Current.reset }

  def offered(user) = WebMcp::Registry.definitions_for(user).map { |definition| definition[:name] }

  test 'every browser tool is defined once, in the shared registries' do
    WebMcp::Registry::READ_TOOLS.each do |name|
      tool = Mcp::Registry.find(name)
      assert tool, "#{name} must be an Mcp::Registry tool"
      assert tool.read_only, "#{name} must be read-only"
    end
    WebMcp::Registry::CONFIRM_TOOLS.each do |name|
      tool = Mcp::Registry.find(name)
      assert tool, "#{name} must be an Mcp::Registry tool"
      assert_not tool.read_only
      assert_not tool.destructive, "#{name}: only non-destructive writes may be offered to a browser assistant"
      assert_includes ApiAccessToken::WRITE_SCOPES, tool.scope
    end
    lookups = AskRupert::Tools.new(user: users(:regular_user)).definitions.map(&:name)
    WebMcp::Registry::LOOKUP_TOOLS.each { |name| assert_includes lookups, name }
  end

  test 'definitions carry the shared schema and description, with WebMCP annotations' do
    definitions = WebMcp::Registry.definitions_for(users(:regular_user)).index_by { |definition| definition[:name] }
    search = definitions.fetch('inventory_search')
    assert_equal Mcp::Tools::InventorySearch.input_schema, search[:inputSchema]
    assert_equal Mcp::Tools::InventorySearch.description, search[:description]
    assert_equal({ readOnlyHint: true, consequentialHint: false, untrustedContentHint: true }, search[:annotations])
    assert_equal false, search[:confirm]

    task = definitions.fetch('create_task')
    assert_equal true, task[:confirm]
    assert_equal true, task[:annotations][:consequentialHint]
    assert_match(/confirm on screen/, task[:description])
    assert_includes task[:description], Mcp::Tools::CreateTask.description

    where = definitions.fetch('where_is')
    assert_equal %w[query], where[:inputSchema][:required]
  end

  test 'nothing offered touches payments, refunds, customers, accounts, settings, backups, keys or exports' do
    forbidden_scopes = %w[customers:read settings:read system:read feedback:read uploads:read uploads:write users:read]
    WebMcp::Registry.names.each do |name|
      assert_no_match WebMcp::Registry::FORBIDDEN, name
      tool = Mcp::Registry.find(name)
      next unless tool

      assert_not_includes forbidden_scopes, tool.scope, "#{name} uses a scope browser tools must not have"
      assert_no_match WebMcp::Registry::FORBIDDEN, tool.scope.to_s
    end
    %w[customer_lookup customer_insights update_task submit_feedback backup_freshness deploy_status activity_log
       list_feedback report_context list_uploads recent_errors ai_health].each do |name|
      assert_not_includes WebMcp::Registry.names, name
    end
  end

  test 'an administrator gets every browser tool' do
    assert_equal WebMcp::Registry.names.sort, offered(users(:regular_user)).sort
  end

  test 'a cashier gets stock and alerts but no reports, timesheets or task writes' do
    names = offered(person(:cashier))
    assert_includes names, 'inventory_search'
    assert_includes names, 'list_alerts'
    assert_includes names, 'where_is'
    %w[business_pulse sales_summary daily_close time_keeping_report create_task list_tasks].each { |name| assert_not_includes names, name }
  end

  test 'a reader can read reports but never write' do
    names = offered(person(:reader))
    assert_includes names, 'sales_summary'
    assert_not_includes names, 'create_task'
    assert_not WebMcp::Registry.available?(person(:reader), 'create_task')
  end

  test 'a manager may create tasks (with confirmation) because they hold projects.write' do
    assert_includes offered(person(:manager)), 'create_task'
  end

  test 'staff self-service, deactivated accounts and a switched-off install get nothing' do
    assert_empty offered(person(:employee))
    inactive = person(:admin)
    inactive.update!(active: false)
    assert_empty offered(inactive)

    ENV['RUPERT_WEBMCP'] = 'off'
    assert_empty offered(users(:regular_user))
  ensure
    ENV.delete('RUPERT_WEBMCP')
  end

  test 'a per-person permission change takes tools away immediately' do
    user = person(:manager)
    assert_includes offered(user), 'inventory_search'
    user.update_permission_overrides!(%w[dashboard.read])
    user.reload
    assert_not_includes offered(user), 'inventory_search'
    assert_not WebMcp::Registry.available?(user, 'inventory_search')
  end

  test 'the page key changes with the person and their permissions' do
    manager = person(:manager)
    key = WebMcp::Registry.key_for(manager)
    assert_equal 16, key.size
    assert_not_equal key, WebMcp::Registry.key_for(person(:manager))
    manager.update!(role: 'reader')
    assert_not_equal key, WebMcp::Registry.key_for(manager.reload)
  end

  test 'the session token allows a write scope only when named, and only with the permission' do
    admin = users(:regular_user)
    assert_not WebMcp::SessionToken.new(admin).allows?('tasks:write')
    assert WebMcp::SessionToken.new(admin, write: 'tasks:write').allows?('tasks:write')
    assert_not WebMcp::SessionToken.new(admin, write: 'tasks:write').allows?('uploads:write')
    assert_not WebMcp::SessionToken.new(person(:reader), write: 'tasks:write').allows?('tasks:write')
    assert_not WebMcp::SessionToken.new(person(:employee)).usable?
    assert_equal "webmcp-#{admin.id}", WebMcp::SessionToken.new(admin).id
  end
end
