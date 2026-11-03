# frozen_string_literal: true

module Compliance
  # Raised when a sale cannot go ahead. Subclasses Pos::Error so the existing
  # register error handling shows its message; #result carries the issues.
  class Blocked < Pos::Error
    attr_reader :result

    def initialize(result, message = nil)
      @result = result
      super(message || result.blocking.map(&:message).join(' '))
    end

    def payload = { error: message, compliance: result.as_json }
  end
end
