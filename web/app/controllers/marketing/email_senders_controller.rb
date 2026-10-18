# frozen_string_literal: true

module Marketing
  class EmailSendersController < BaseController
    before_action :authorize_write
    before_action :authorize_review

    def create
      EmailSender.create!(tenant_id: Current.tenant_id, email_domain: EmailDomain.find(params.require(:sender)[:email_domain_id]),
        **params.require(:sender).permit(:from_name, :local_part, :reply_to).to_h.symbolize_keys)
      redirect_to(marketing_email_path, notice: 'Sender saved.')
    end
  end
end
