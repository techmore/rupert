# frozen_string_literal: true

# Email domains permitted to sign in via Google OAuth. Scoped per tenant so
# one store's domain list can't be changed by another. An empty list for a
# tenant = Google sign-in is disabled for that store until a domain is allowed.
class OauthAllowedDomain < ApplicationRecord
  include TenantScoped

  validates :domain,
    presence: true,
    uniqueness: { scope: :tenant_id, case_sensitive: false },
    format: { with: /\A[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+\.?[a-z]*\z/, message: "must look like example.com" }

  before_validation { self.domain = domain.to_s.downcase.strip.sub(/\A@/, "") }

  # Does this tenant allow Google sign-in for the email's domain? Defaults to
  # Current.tenant; callers on the pre-auth callback (where Current.tenant may
  # be nil on the root domain) pass the resolved tenant explicitly. Queries are
  # unscoped because the tenant is always given explicitly here.
  def self.allowed?(email, tenant: Current.tenant)
    return false if email.blank? || tenant.nil?

    domain = email.split("@").last.to_s.downcase
    unscoped.exists?(tenant_id: tenant.id, domain: domain)
  end
end
