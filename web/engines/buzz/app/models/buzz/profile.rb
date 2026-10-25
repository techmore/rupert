# frozen_string_literal: true

module Buzz
  # A Buzz identity's public name (its kind 0 profile), cached so the chat shows a
  # person instead of a key. Chosen by that person, so untrusted: cleaned and
  # capped on the way in, escaped on display.
  class Profile < ApplicationRecord
    include TenantScoped

    REFRESH_AFTER = 6.hours

    scope :fresh, -> { where(fetched_at: REFRESH_AFTER.ago..) }

    def label
      display_name.presence || name.presence
    end
  end
end
