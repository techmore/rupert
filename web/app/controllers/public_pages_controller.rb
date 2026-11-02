# frozen_string_literal: true

# Public pages anyone can open, signed in or not: the privacy policy and support page that the
# App Store listing links to (pos.rupertpos.com/privacy, pos.rupertpos.com/support). They use the normal
# layout, so they load Turbo and also open inside the iPhone app.
class PublicPagesController < ApplicationController
  skip_before_action :require_login
  # The plain-text site maps read no workspace data, whoever is signed in.
  skip_before_action :restrict_employee_workspace, only: %i[llms llms_full]

  def privacy; end

  def support
    @support_email = self.class.support_email
  end

  # GET /llms.txt and /llms-full.txt — the public site for AI assistants (https://llmstxt.org).
  # A private single-store node has no public site to describe.
  def llms
    render_llms(WebMcp::PublicSite.llms_txt)
  end

  def llms_full
    render_llms(WebMcp::PublicSite.llms_full_txt)
  end

  def self.support_email
    ENV['RUPERT_SUPPORT_EMAIL'].presence || 'support@rupertpos.com'
  end

  private

  def render_llms(text)
    return head(:not_found) if WorkspaceNode.isolated?

    expires_in 1.hour, public: true
    render plain: text, content_type: 'text/markdown; charset=utf-8'
  end
end
