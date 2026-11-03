# frozen_string_literal: true

module Mcp
  # Base class for MCP tools. A tool declares its name, the token scope it
  # needs (nil = every valid token) and a JSON Schema for its arguments.
  # Subclasses implement #call(args) and return Mcp::Result.
  class Tool
    MAX_PER_PAGE = 50
    MAX_PAGE = 1000

    class << self
      attr_reader :tool_name, :title, :description, :scope, :read_only, :destructive, :idempotent, :output_schema_definition

      def tool(name, title:, description:, scope: nil, read_only: true, destructive: false, idempotent: read_only)
        @tool_name = name
        @title = title
        @description = description
        @scope = scope
        @read_only = read_only
        @destructive = destructive
        @idempotent = idempotent
      end

      def input_schema(schema = nil)
        @input_schema = schema if schema
        @input_schema || { type: 'object', properties: {}, additionalProperties: false }
      end

      def output_schema(schema)
        @output_schema_definition = schema
      end

      def permission
        scope && ApiAccessToken::SCOPES[scope]
      end

      def available_to?(token)
        return false unless token&.usable?

        scope.nil? || token.allows?(scope)
      end

      def annotations
        { title: title, readOnlyHint: read_only, destructiveHint: destructive, idempotentHint: idempotent, openWorldHint: false }
      end

      def definition
        {
          name: tool_name, title: title, description: description,
          inputSchema: input_schema, annotations: annotations
        }.tap { |hash| hash[:outputSchema] = output_schema_definition if output_schema_definition }
      end
    end

    PAGE_PROPERTIES = {
      page: { type: 'integer', minimum: 1, maximum: MAX_PAGE, description: 'Page number, starting at 1. Default 1.' },
      per_page: { type: 'integer', minimum: 1, maximum: MAX_PER_PAGE, description: "Rows per page, 1–#{MAX_PER_PAGE}. Default 25." }
    }.freeze

    DATE_PROPERTY = { type: 'string', format: 'date', description: 'ISO date, YYYY-MM-DD (a full ISO timestamp is also accepted; its date part is used).' }.freeze

    AS_OF_PROPERTY = { type: 'string', format: 'date', description: 'Optional replay date, YYYY-MM-DD: treat this date as today when resolving ' \
                                                                    'named periods and default dates (so a question gives the same answer on any day). ' \
                                                                    'Not after tomorrow. Explicit from/to dates are unaffected. Echoed back as as_of.' }.freeze

    attr_reader :token, :user, :tenant

    def initialize(token:)
      @token = token
      @user = token.user
      @tenant = token.tenant
    end

    def call(_args)
      raise NotImplementedError
    end

    private

    def result(text, data)
      Result.new(text: text, data: data)
    end

    # ISO date or timestamp → Date. Blank → default.
    def date_arg(args, key, default)
      value = args[key.to_s]
      return default if value.blank?

      match = value.to_s.strip.match(/\A(\d{4}-\d{2}-\d{2})/)
      raise ToolError.new("#{key} must be an ISO date like 2026-10-01.", kind: 'invalid_arguments') unless match

      Date.iso8601(match[1])
    rescue Date::Error
      raise ToolError.new("#{key} is not a real calendar date: #{value.to_s.first(40)}.", kind: 'invalid_arguments')
    end

    # The optional as_of date, or nil. A date after tomorrow is refused (one day of slack covers time zones).
    def as_of_date(args)
      value = date_arg(args, 'as_of', nil)
      raise ToolError.new("as_of cannot be after tomorrow (#{(Date.current + 1).iso8601}).", kind: 'invalid_arguments') if value && value > Date.current + 1

      value
    end

    # What "today" means for this call: as_of when given, else the real current date.
    def today(args) = as_of_date(args) || Date.current

    # Adds as_of to structured data when the caller supplied one, so a reader can see the basis.
    def with_as_of(data, args)
      as_of = as_of_date(args)
      as_of ? data.merge(as_of: as_of.iso8601) : data
    end

    def as_of_note(args)
      as_of = as_of_date(args)
      as_of ? " (as of #{as_of.iso8601})" : ''
    end

    def date_range(args, default_from:, default_to: nil, max_days: 400)
      from = date_arg(args, 'from', default_from)
      to = date_arg(args, 'to', default_to || today(args))
      raise ToolError.new('to must be on or after from.', kind: 'invalid_arguments') if to < from
      raise ToolError.new("Choose a range of #{max_days} days or fewer.", kind: 'invalid_arguments') if (to - from).to_i >= max_days

      [from, to]
    end

    def page_args(args, default_per_page: 25)
      page = (args['page'] || 1).to_i.clamp(1, MAX_PAGE)
      per_page = (args['per_page'] || default_per_page).to_i.clamp(1, MAX_PER_PAGE)
      [page, per_page]
    end

    # Pages an ActiveRecord scope or an array. Returns [rows, meta].
    def paginate(collection, args, default_per_page: 25)
      page, per_page = page_args(args, default_per_page: default_per_page)
      offset = (page - 1) * per_page
      rows = collection.is_a?(Array) ? collection.slice(offset, per_page + 1) || [] : collection.offset(offset).limit(per_page + 1).to_a
      more = rows.size > per_page
      meta = { page: page, per_page: per_page, has_more: more, next_page: more && page < MAX_PAGE ? page + 1 : nil }
      meta[:total] = collection.size if collection.is_a?(Array)
      [rows.first(per_page), meta]
    end

    def cents(value)
      value.nil? ? nil : value.to_i
    end

    def money(cents)
      Money.format(cents, unit: false, minus: '-', delimiter: '', missing: 'unavailable')
    end

    def iso(time)
      time&.iso8601
    end
  end
end
