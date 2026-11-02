# frozen_string_literal: true

require 'digest'

module WebMcp
  # Which tools the signed-in app offers to a browser assistant. Nothing here is
  # defined twice: the data tools are the shared Mcp::Registry classes (the same
  # names, descriptions and JSON schemas the /mcp server, Ask Rupert and team chat
  # use), and the lookups are Ask Rupert's own where_is and how_do_i.
  #
  # The list is an allow-list on purpose. A new MCP tool does not reach browsers
  # until someone adds it here, and the policy test refuses anything that touches
  # payments, refunds, customers, accounts, settings, backups, keys or exports.
  module Registry
    # Read-only data tools from Mcp::Registry.
    READ_TOOLS = %w[
      business_pulse sales_summary daily_close order_queues
      inventory_search list_alerts time_keeping_report list_tasks data_guide
    ].freeze
    # Ask Rupert's navigation lookups (AskRupert::Tools): pages and lessons this person can open.
    LOOKUP_TOOLS = %w[where_is how_do_i].freeze
    # Low-risk writes to Rupert's own data. Each needs the person to confirm on screen first.
    CONFIRM_TOOLS = %w[create_task].freeze

    # Words that must never appear in an offered tool's name or scope (checked by tests).
    FORBIDDEN = /payment|card|charge|refund|customer|user|role|permission|setting|backup|key|secret|token|export|upload|feedback|deploy|activity|error|health/

    module_function

    def names = READ_TOOLS + LOOKUP_TOOLS + CONFIRM_TOOLS

    def confirm?(name) = CONFIRM_TOOLS.include?(name.to_s)
    def lookup?(name) = LOOKUP_TOOLS.include?(name.to_s)

    # The shared MCP tool class for a name, or nil (lookups have none).
    def mcp_tool(name)
      return unless (READ_TOOLS + CONFIRM_TOOLS).include?(name.to_s)

      Mcp::Registry.find(name.to_s)
    end

    # True when this person may use this tool right now (current permissions, active account and store).
    def available?(user, name)
      name = name.to_s
      return false unless WebMcp.enabled? && user && names.include?(name)

      token = SessionToken.new(user, write: write_scope(name))
      return false unless token.usable?
      return lookup_definitions(user).any? { |definition| definition.name == name } if lookup?(name)

      tool = mcp_tool(name)
      return false unless tool
      return tool.read_only && tool.available_to?(token) unless confirm?(name)

      tool.available_to?(token) && Projects::TaskPolicy.new(user, Projects::Task).create?
    end

    def write_scope(name)
      confirm?(name) ? mcp_tool(name)&.scope : nil
    end

    # The tool list for the browser, in the shape document.modelContext.registerTool takes
    # (minus execute, which the page adds). `confirm` tells the page to ask the person first.
    def definitions_for(user)
      names.select { |name| available?(user, name) }.map { |name| definition(user, name) }
    end

    # Changes whenever the person, their permissions or the tool list change, so the page
    # re-registers after a sign-in, sign-out or permission change without a reload.
    def key_for(user)
      return nil unless user

      Digest::SHA256.hexdigest([user.id, user.tenant_id, user.permissions_signature, names.join(','), WebMcp.enabled?].join('|')).first(16)
    end

    def definition(user, name)
      if lookup?(name)
        lookup = lookup_definitions(user).find { |candidate| candidate.name == name }
        return {
          name: name, title: name == 'where_is' ? 'Find a page in Rupert' : 'How do I… (Learn Rupert)',
          description: "#{lookup.description} Results are links inside Rupert the person can open.",
          inputSchema: { type: 'object', properties: lookup.properties, required: lookup.required, additionalProperties: false },
          annotations: annotations(read_only: true), confirm: false
        }
      end

      tool = mcp_tool(name)
      description = tool.description
      if confirm?(name)
        description = 'Rupert asks the signed-in person to confirm on screen before anything is saved; ' \
                      "if they decline, nothing changes. #{description}"
      end
      {
        name: name, title: tool.title, description: description, inputSchema: tool.input_schema,
        annotations: annotations(read_only: tool.read_only), confirm: confirm?(name)
      }
    end

    # WebMCP ToolAnnotations. Results can contain text other people typed (item names, task notes),
    # so every tool is marked untrusted content; writes are consequential.
    def annotations(read_only:)
      { readOnlyHint: read_only, consequentialHint: !read_only, untrustedContentHint: true }
    end

    def lookup_definitions(user)
      AskRupert::Tools.new(user: user).definitions.select { |definition| LOOKUP_TOOLS.include?(definition.name) }
    end
  end
end
