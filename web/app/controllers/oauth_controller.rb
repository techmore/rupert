# frozen_string_literal: true

# Google sign-in for the login page. Reaches Google before the user is
# authenticated, so it must skip the usual require_login gate.
#
# Flow:
#   GET /auth/google              → redirect to Google's consent screen
#   GET /auth/google/callback     → exchange code, verify domain, sign in
#
# Domain enforcement: the user's email domain must be in the tenant's
# OauthAllowedDomain list. Unknown domains are rejected; known domains with an
# existing Rupert account sign in, and known domains without one get a reader
# account auto-provisioned.
class OauthController < ApplicationController
  class AccountInAnotherTenant < StandardError; end

  skip_before_action :require_login, only: %i[authorize callback]

  def authorize
    state = SecureRandom.hex(24)
    session[:oauth_state] = state
    AccessLogger.record(source: 'google', status: 'attempt', request: request, detail: 'Google sign-in started')
    redirect_to(
      GoogleOauthService.auth_url(redirect_uri: google_callback_url, state: state),
      allow_other_host: true
    )
  rescue GoogleOauthService::NotConfiguredError => e
    AccessLogger.record(source: 'google', status: 'failure', request: request, detail: 'not configured')
    redirect_to(login_path, alert: e.message)
  end

  def callback
    info = nil
    tested_domain = params[:hd].presence
    if params[:error].present?
      AccessLogger.record(source: 'google', status: 'failure', request: request, domain: tested_domain,
                          detail: 'consent declined')
      return redirect_to(login_path, alert: 'Google sign-in was declined.')
    end
    if session[:oauth_state].blank? || session[:oauth_state] != params[:state]
      AccessLogger.record(source: 'google', status: 'failure', request: request, domain: tested_domain,
                          detail: 'state check failed')
      return redirect_to(login_path, alert: 'Google sign-in failed the state check. Try again.')
    end

    info = GoogleOauthService.exchange_code!(params[:code], redirect_uri: google_callback_url)
    session.delete(:oauth_state)

    email = info['email'].to_s.downcase
    tested_domain ||= email.split('@').last
    tenant = resolve_tenant
    unless tenant && OauthAllowedDomain.allowed?(email, tenant: tenant)
      AccessLogger.record(
        source: 'google',
        status: 'failure',
        request: request,
        email: email,
        domain: tested_domain,
        detail: 'domain not allowed'
      )
      return redirect_to(login_path,
                         alert: "Your Google account (#{email}) isn't on an allowed domain. Ask an admin to allow #{email.split('@').last}.")
    end

    user = find_or_create_user!(email, info, tenant)
    unless user&.active?
      AccessLogger.record(
        source: 'google',
        status: 'failure',
        request: request,
        email: email,
        domain: tested_domain,
        detail: 'deactivated account'
      )
      return redirect_to(login_path, alert: 'This account has been deactivated. Contact an admin.')
    end

    reset_session # prevent session fixation
    session[:user_id] = user.id
    AccessLogger.record(source: 'google', status: 'success', request: request, user: user, email: email,
                        domain: tested_domain)
    redirect_to(root_path, notice: 'Signed in with Google.')
  rescue GoogleOauthService::NotConfiguredError, GoogleOauthService::ExchangeError => e
    session.delete(:oauth_state)
    AccessLogger.record(source: 'google', status: 'failure', request: request, email: info&.dig('email'),
                        domain: tested_domain || info&.dig('email')&.split('@')&.last, detail: e.message.to_s[0, 200])
    redirect_to(login_path, alert: e.message)
  rescue AccountInAnotherTenant => e
    session.delete(:oauth_state)
    AccessLogger.record(source: 'google', status: 'failure', request: request, email: e.message,
                        domain: e.message.to_s.split('@').last, detail: 'account belongs to another tenant')
    redirect_to(login_path,
                alert: 'This Google account already belongs to another workspace. Ask the workspace admin to invite you.')
  rescue StandardError => e
    session.delete(:oauth_state)
    AccessLogger.record(source: 'google', status: 'failure', request: request, email: info&.dig('email'),
                        domain: tested_domain || info&.dig('email')&.split('@')&.last, detail: "#{e.class}: #{e.message.to_s[0, 160]}")
    raise
  end

  private

  # The tenant a Google sign-in belongs to. On a subdomain this is the store;
  # on the root domain a lone tenant (single-store install) is assumed.
  def resolve_tenant
    return Current.tenant if Current.tenant
    return Tenant.first if Tenant.count == 1

    nil
  end

  # A user's account is tenant-scoped: resolve to the account in the subdomain's
  # tenant, never a same-email account belonging to another tenant.
  def find_or_create_user!(email, info, tenant)
    user = User.find_by(email: email, tenant_id: tenant.id)
    return user if user

    raise AccountInAnotherTenant, email if User.exists?(email: email)

    user = tenant.users.new(
      email: email,
      name: info['name'].presence || email.split('@').first.titleize,
      role: 'reader',
      password: SecureRandom.hex(24)
    )
    user.save!
    ActivityLogger.log('employee_added', subject: user, details: 'via Google sign-in')
    user
  end
end
