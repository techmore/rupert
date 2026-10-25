# frozen_string_literal: true

module Buzz
  # A Buzz channel the Rupert identity belongs to: its name and member list as the
  # relay last said (kind 39000 and 39002 events). A copy; the relay decides. The
  # names and descriptions were written by other people and are untrusted text.
  class Channel < ApplicationRecord
    include TenantScoped

    REFRESH_AFTER = 60.seconds
    TYPES = ['stream'].freeze # forums, DMs and workflow rooms are not chat rooms

    scope :active, -> { where(archived: false, channel_type: TYPES).order(:name) }

    # [[pubkey, role], ...]
    def member_list
      list = JSON.parse(members)
      list.is_a?(Array) ? list : []
    rescue JSON::ParserError
      []
    end

    def member_pubkeys = member_list.map(&:first)

    def self.stale?(now: Time.current)
      newest = maximum(:fetched_at)
      newest.nil? || newest < now - REFRESH_AFTER
    end
  end
end
