# frozen_string_literal: true

# Plain-language guide to the services Rupert connects to: what keys each
# needs, where to find them, and how to renew them.
class ConnectionsController < AuthenticatedController
  before_action :authorize_read

  def index
    @services = ConnectionsGuide.services
    @configured = ConnectionsGuide.configured_count
  end

  private

  def authorize_read
    authorize(:module, :settings_read?)
  end
end
