# frozen_string_literal: true

# Lets an admin hide the "update available" banner for the build it is about.
class UpdateNoticesController < AuthenticatedController
  # Writes only this browser session's dismissal; no workspace data is read or changed.
  skip_after_action :verify_authorized

  def dismiss
    session[:dismissed_update_for] = BuildInfo.current.revision
    redirect_back(fallback_location: root_path)
  end
end
