# frozen_string_literal: true

require 'test_helper'

# The published API contract (docs/api-standards.md, docs/mcp.md) names every
# scope, MCP tool and /api/v1 resource the code exposes. Adding one without
# documenting it fails here.
class ApiDocsContractTest < ActiveSupport::TestCase
  DOCS = Rails.root.join('..', 'docs')

  def standards = DOCS.join('api-standards.md').read
  def mcp_guide = DOCS.join('mcp.md').read

  test 'every token scope and its owner permission is in the API standards table' do
    ApiAccessToken::SCOPES.each do |scope, permission|
      row = /^\| `#{Regexp.escape(scope)}` \| #{permission ? "`#{Regexp.escape(permission)}`" : 'none'}/
      assert_match row, standards, "#{scope} → #{permission.inspect} is not documented in docs/api-standards.md §3"
    end
  end

  test 'every write scope is named as a write' do
    ApiAccessToken::WRITE_SCOPES.each do |scope|
      assert_includes standards, "`#{scope}`", "#{scope} missing from the Writes paragraph"
    end
  end

  test 'every MCP tool is in the MCP guide table' do
    Mcp::Registry.tools.each do |tool|
      assert_match(/^\| `#{Regexp.escape(tool.tool_name)}` \|/, mcp_guide, "#{tool.tool_name} is not documented in docs/mcp.md §3")
    end
  end

  test 'every writing MCP tool is marked as writing' do
    Mcp::Registry.tools.reject(&:read_only).each do |tool|
      assert_match(/^\| `#{tool.tool_name}` \|[^\n]*\*\*Writes/, mcp_guide, "#{tool.tool_name} writes but is not marked **Writes** in docs/mcp.md")
    end
  end

  test 'every /api/v1 resource is named in the API standards' do
    resources = Rails.application.routes.routes.filter_map do |route|
      route.path.spec.to_s[%r{\A/api/v1/([a-z_]+)}, 1]
    end.uniq
    assert_includes resources, 'catalog'
    resources.each do |resource|
      assert_includes standards, resource, "/api/v1/#{resource} is not mentioned in docs/api-standards.md"
    end
  end

  test 'documented MCP limits match the code' do
    assert_equal 50, Mcp::Tool::MAX_PER_PAGE
    assert_includes standards, '`per_page` (1–50, default 25)'
    assert_equal 200_000, Mcp::Server::MAX_RESULT_BYTES
    assert_includes standards, 'Results over 200 KB'
    Mcp::Server::PROTOCOL_VERSIONS.each { |version| assert_includes standards, "`#{version}`" }
  end
end
