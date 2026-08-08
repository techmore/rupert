# frozen_string_literal: true

# Base controller for signed-in, tenant-scoped pages. Includes Pundit so every
# action can authorize against a policy, and the shared nav is built from the
# module registry.
class AuthenticatedController < ApplicationController
  include Pundit::Authorization
  include Pagy::Backend

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  def pundit_user
    Current.user
  end

  def user_not_authorized
    flash[:alert] = "You don't have permission to do that."
    redirect_to(request.referer || root_path)
  end
end
