# frozen_string_literal: true

# Runs the static sales announcer after a sync. Safe by construction: the
# announcer no-ops when Buzz isn't configured or there's nothing new.
class SalesAnnouncementJob < ApplicationJob
  queue_as :default

  def perform
    SalesAnnouncer.announce!
  rescue StandardError
    nil
  end
end
