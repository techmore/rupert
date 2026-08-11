# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login, only: [:new, :create]

  def new
    redirect_to(root_path) if Current.user
  end

  def create
    user = User.find_by(email: params[:email].to_s.downcase)
    if user&.active? && user.authenticate(params[:password])
      reset_session # prevent session fixation
      session[:user_id] = user.id
      redirect_to(root_path, notice: "Signed in")
    else
      flash.now[:alert] = "Invalid email or password"
      render(:new, status: :unprocessable_entity)
    end
  end

  def destroy
    session.delete(:user_id)
    Current.user = nil
    redirect_to(login_path, notice: "Signed out")
  end
end
