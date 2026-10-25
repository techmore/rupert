# frozen_string_literal: true

module Buzz
  # How far one person has read a channel (the posted_at of the newest message
  # they have seen), which is what the unread markers count from.
  class ChatRead < ApplicationRecord
    include TenantScoped

    belongs_to :user, class_name: 'User'
  end
end
