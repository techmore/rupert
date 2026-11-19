# frozen_string_literal: true

module WebMcp
  # Lets the shared MCP tools run in-process as the signed-in person for one
  # browser request. It is not a stored token and grants nothing the person does
  # not already have: every scope is checked against their current permissions,
  # and a write scope is allowed only when the caller names it for a call the
  # person has just confirmed on screen.
  class SessionToken
    attr_reader :user, :tenant

    def initialize(user, write: nil)
      @user = user
      @tenant = user.tenant
      @write = write
    end

    # The id keys the per-person task-write cap and idempotency keys (Mcp::TaskWriteGuard).
    def id = "webmcp-#{user.id}"
    def name = 'Browser assistant (WebMCP)'
    def token_hint = 'webmcp'
    def expires_at = nil

    def scopes = ApiAccessToken::SCOPES.keys.select { |scope| allows?(scope) }

    def usable?
      !!(user.active? && !user.employee? && tenant&.status == 'active' && user.tenant_id == tenant.id)
    end

    def allows?(scope)
      return false unless usable? && ApiAccessToken::SCOPES.key?(scope)
      return false if ApiAccessToken::WRITE_SCOPES.include?(scope) && scope != @write

      permission = ApiAccessToken::SCOPES[scope]
      permission.nil? || user.can?(permission)
    end
  end
end
