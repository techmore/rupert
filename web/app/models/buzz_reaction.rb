# frozen_string_literal: true

# One reaction (a NIP-25 kind 7 event) to a channel message, copied from the Buzz
# relay. Reactions posted from Rupert are signed by the agent key like every other
# post, so rupert_user_id says which person asked for it (only used for rate limits).
class BuzzReaction < ApplicationRecord
  include TenantScoped

  EMOJI_MAX = 64
  # What the page offers. Reactions from other apps show whatever they sent.
  QUICK = %w[👍 ❤️ 😂 🎉 👀 ✅].freeze

  belongs_to :rupert_user, class_name: 'User', optional: true
end
