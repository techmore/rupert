# frozen_string_literal: true

class ApplicationController < ActionController::Base
  before_action :set_current_context
  before_action :load_last_sync
  before_action :require_login

  private

  def set_current_context
    Current.user = session[:user_id] ? User.find_by(id: session[:user_id]) : nil

    if Current.user&.super_admin?
      Current.tenant = Tenant.find_by(subdomain: request.subdomain)
    else
      Current.tenant = Current.user&.tenant
      Current.tenant ||= Tenant.find_by(subdomain: request.subdomain) if Current.user.nil?
    end
  end

  def require_login
    return redirect_to(setup_path) if Current.user.nil? && !Tenant.exists?

    redirect_to(login_path, alert: "Please sign in") unless Current.user
  end

  def load_last_sync
    @last_sync = Current.user ? SyncRun.order(startedAt: :desc).first : nil
  end
end
