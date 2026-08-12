# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login, only: [:new, :create]

  def new
    redirect_to(root_path) if Current.user
    @google_configured = GoogleOauthService.configured?
  end

  def create
    user = User.find_by(email: params[:email].to_s.downcase)
    if user&.active? && user.authenticate(params[:password])
      reset_session # prevent session fixation
      session[:user_id] = user.id
      AccessLogger.record(source: "password", status: "success", request: request, user: user)
      redirect_to(root_path, notice: "Signed in")
    else
      AccessLogger.record(
        source: "password",
        status: "failure",
        request: request,
        email: params[:email],
        detail: user ? "invalid password" : "unknown email",
      )
      flash.now[:alert] = "Invalid email or password"
      render(:new, status: :unprocessable_entity)
    end
  end

  def destroy
    AccessLogger.record(source: "logout", status: "success", request: request, user: Current.user)
    session.delete(:user_id)
    Current.user = nil
    redirect_to(login_path, notice: "Signed out")
  end
end
