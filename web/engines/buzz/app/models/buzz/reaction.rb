# frozen_string_literal: true

module Buzz
  # One reaction (a NIP-25 kind 7 event) to a copied message. Reactions sent from
  # Rupert are signed by the Rupert identity like every post, so rupert_user_id
  # says which person asked for it (used for rate limits only).
  class Reaction < ApplicationRecord
    include TenantScoped

    EMOJI_MAX = 64
    # What the page offers. Reactions from other apps show whatever they sent.
    QUICK = ['👍', '❤️', '😂', '🎉', '👀', '✅'].freeze

    belongs_to :rupert_user, class_name: 'User', optional: true
  end
end
