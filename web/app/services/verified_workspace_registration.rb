# frozen_string_literal: true

# A verified mailbox grants only its own workspace, never a whole email domain.
class VerifiedWorkspaceRegistration
  def self.call(info:, attributes:)
    unless [true, 'true'].include?(info['email_verified']) && info['sub'].present?
      raise GoogleOauthService::ExchangeError, 'A verified Google identity is required.'
    end
    email = info['email'].to_s.strip.downcase
    raise GoogleOauthService::ExchangeError, 'This account already exists. Use Sign in.' if User.exists?(email: email) || GoogleLoginIdentity.exists?(email: email)
    # Never turn a customer registration into a privileged operator account.
    if PlatformOwnerIdentities.emails.include?(email)
      raise GoogleOauthService::ExchangeError, 'Use your existing administrator sign-in or ask an operator to link this identity.'
    end
    # Self-service (off by default): the sign-up form recorded the accepted terms version; the new
    # workspace is billable (not exempt) and starts its trial now. With the switch off the workspace
    # keeps the column default (exempt) and a plain free record, exactly as before.
    self_service = SelfService.enabled?
    if self_service && attributes['terms_version'].blank?
      raise GoogleOauthService::ExchangeError, 'Accept the terms of service to create an account.'
    end
    Tenant.transaction do
      tenant = Tenant.new(name: attributes.fetch('workspace_name'), subdomain: attributes.fetch('requested_subdomain'))
      tenant.billing_exempt = false if self_service
      tenant.save!
      user = User.create!(tenant: tenant, email: email, name: info['name'].presence || email, role: 'admin', active: true, password: SecureRandom.hex(32))
      GoogleLoginIdentity.create!(user: user, email: email, google_subject: info['sub'])
      if self_service
        CustomerSubscription.create!(tenant: tenant, trial_ends_at: SelfService.trial_days.days.from_now,
          signup_terms_version: attributes['terms_version'].to_s.first(40), signup_terms_accepted_at: Time.current)
      else
        CustomerSubscription.create!(tenant: tenant)
      end
      WorkspaceDeployment.request!(tenant: tenant, owner: user)
      user
    end
  rescue ActiveRecord::RecordNotUnique
    raise GoogleOauthService::ExchangeError, 'This account or workspace address already exists. Sign in or choose another address.'
  end
end
