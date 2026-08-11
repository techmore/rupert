# frozen_string_literal: true

# Email domains permitted to sign in via Google OAuth. Empty table = Google
# sign-in is effectively disabled until at least one domain is allowed.
class OauthAllowedDomain < ApplicationRecord
  validates :domain,
    presence: true,
    uniqueness: { case_sensitive: false },
    format: { with: /\A[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+\.?[a-z]*\z/, message: "must look like example.com" }

  before_validation { self.domain = domain.to_s.downcase.strip.sub(/\A@/, "") }

  def self.allowed?(email)
    return false if email.blank?

    domain = email.split("@").last.to_s.downcase
    exists?(domain: domain)
  end
end
