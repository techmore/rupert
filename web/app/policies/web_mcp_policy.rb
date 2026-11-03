# frozen_string_literal: true

# Who may use the in-browser assistant tools at all (WebMcpController). Which
# tools they get is decided per tool by WebMcp::Registry against the same
# permissions the pages use. Staff self-service accounts get none.
class WebMcpPolicy < ApplicationPolicy
  def use?
    !!(WebMcp.enabled? && user&.active? && !user.employee? && user.tenant_id.present? && user.tenant_id == Current.tenant_id)
  end
end
