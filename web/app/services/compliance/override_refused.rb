# frozen_string_literal: true

module Compliance
  # A manager override that was refused (wrong PIN, not a manager, locked out).
  class OverrideRefused < Blocked; end
end
