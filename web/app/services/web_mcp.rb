# frozen_string_literal: true

# WebMCP: Rupert's pages offer tools to an AI assistant running in the person's
# own browser (W3C Web Machine Learning CG draft, `document.modelContext`).
#
# - The public site offers read-only facts (what Rupert is, pricing, contact,
#   how to get a demo) from WebMcp::PublicSite, the same facts as /llms.txt.
# - The signed-in app offers a small allow-listed subset of the shared tool
#   registry (Mcp::Registry, also behind /mcp, Ask Rupert and team chat) plus
#   Ask Rupert's navigation lookups. They run as the signed-in person through
#   the normal session, CSRF and permission checks. See docs/webmcp.md.
module WebMcp
  # Operators can switch the browser tools off without a deploy: RUPERT_WEBMCP=off.
  def self.enabled?
    !%w[off 0 false].include?(ENV.fetch('RUPERT_WEBMCP', 'on').to_s.strip.downcase)
  end
end
