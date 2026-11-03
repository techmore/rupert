# frozen_string_literal: true

# Public pages anyone can open, signed in or not: the privacy policy and support page that the
# App Store listing links to (pos.rupertpos.com/privacy, pos.rupertpos.com/support), plus the terms,
# cancellation and refund policy, security statement and integrations list that payment partners
# and card-brand website rules expect. They use the normal layout, so they load Turbo and also open
# inside the iPhone app. Keep prices and checkout links off them (App Store guideline 3.1.1).
class PublicPagesController < ApplicationController
  skip_before_action :require_login

  # Business identity shown on these pages. Each value comes from the deployment's environment;
  # a blank value renders a visible "Owner to add" placeholder rather than an invented fact.
  # The name the privacy policy and Stripe billing already use.
  OPERATOR_NAME = 'CSP Cyber Security Pilot'
  COMPANY_ENV = {
    legal_name: 'RUPERT_LEGAL_NAME',          # registered entity name and state, e.g. "Example LLC (Delaware)"
    address: 'RUPERT_BUSINESS_ADDRESS',       # principal place of business (not a PO box)
    phone: 'RUPERT_SUPPORT_PHONE',
    hours: 'RUPERT_SUPPORT_HOURS',
    hosting_location: 'RUPERT_HOSTING_LOCATION',
    security_email: 'RUPERT_SECURITY_EMAIL'   # falls back to the support address
  }.freeze

  def privacy; end
  def terms; end
  def refunds; end
  def security; end
  def integrations; end

  def support
    @support_email = self.class.support_email
  end

  def self.support_email
    ENV['RUPERT_SUPPORT_EMAIL'].presence || 'sdolbec@rupertpos.com'
  end

  def self.company
    # ENV strings arrive as binary; read them as UTF-8 so "Mon–Fri" or "Montréal" render.
    values = COMPANY_ENV.transform_values { |key| ENV[key].presence&.dup&.force_encoding(Encoding::UTF_8)&.scrub }
    values.tap do |company|
      company[:security_email] ||= support_email
    end
  end
end
