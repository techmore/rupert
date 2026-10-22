# frozen_string_literal: true

# A Buzz channel the Rupert agent is a member of: its name and member list as the
# relay last said (kind 39000 and 39002 events). A copy; the relay decides. The
# names and descriptions were written by other people and are untrusted text.
class BuzzChannel < ApplicationRecord
  include TenantScoped

  REFRESH_AFTER = 60.seconds
  TYPES = %w[stream].freeze # forums, DMs and workflow rooms are not chat rooms

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
    maximum(:fetched_at).nil? || maximum(:fetched_at) < now - REFRESH_AFTER
  end
end
