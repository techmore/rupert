# frozen_string_literal: true

module Marketing
  class EmailDomainsController < BaseController
    before_action :authorize_write
    before_action :authorize_review
    rescue_from EmailProvider::Error, with: :provider_error

    def create
      EmailDomainWorkflow.add_custom!(params[:domain], actor: Current.user)
      redirect_to(marketing_email_path, notice: 'Domain added. Publish the DNS records below, then check it.')
    end

    def shared
      EmailDomainWorkflow.add_shared!(actor: Current.user)
      redirect_to(marketing_email_path, notice: 'Shared sending domain ready.')
    end

    def check
      record = EmailDomain.find(params[:id])
      EmailDomainWorkflow.check!(record, actor: Current.user)
      redirect_to(marketing_email_path, notice: record.verified? ? 'Domain verified.' : 'DNS records not found yet. They can take a while to propagate.')
    end

    private

    def provider_error(error)
      redirect_to(marketing_email_path, alert: error.message)
    end
  end
end
