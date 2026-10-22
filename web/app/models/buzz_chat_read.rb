# frozen_string_literal: true

# How far one person has read a Team chat channel (the posted_at of the newest
# message they have seen), which is what the unread markers count from.
class BuzzChatRead < ApplicationRecord
  include TenantScoped

  belongs_to :user
end
