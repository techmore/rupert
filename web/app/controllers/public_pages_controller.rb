# frozen_string_literal: true

# Public pages anyone can open, signed in or not: the privacy policy and support page that the
# App Store listing links to (rupertpos.com/privacy, rupertpos.com/support). They use the normal
# layout, so they load Turbo and also open inside the iPhone app.
class PublicPagesController < ApplicationController
  skip_before_action :require_login

  def privacy; end

  def support
    @support_email = self.class.support_email
  end

  def self.support_email
    ENV['RUPERT_SUPPORT_EMAIL'].presence || 'support@rupertpos.com'
  end
end
