# frozen_string_literal: true

# Bounce, spam-complaint and unsubscribe events from the platform's email provider.
# Authenticated with a shared secret in the URL basic-auth password, not a session.
class PostmarkWebhooksController < ActionController::API
  def create
    secret = ENV.fetch('POSTMARK_WEBHOOK_SECRET', '')
    _user, supplied = ActionController::HttpAuthentication::Basic.user_name_and_password(request) rescue [nil, nil]
    return head(:unauthorized) if secret.blank? || !ActiveSupport::SecurityUtils.secure_compare(supplied.to_s, secret)

    event = JSON.parse(request.body.read(65_536).to_s)
    recipient = Marketing::EmailRecipient.unscoped.find_by(provider_message_id: event['MessageID'].to_s) if event['MessageID'].present?
    return head(:ok) unless recipient

    Current.set(tenant: Tenant.find(recipient.tenant_id)) do
      case event['RecordType']
      when 'Bounce'
        recipient.update!(status: 'bounced')
        Marketing::EmailSuppression.add!(recipient.email, 'bounced') if event['Type'].to_s.match?(/HardBounce|BadEmail/)
      when 'SpamComplaint'
        recipient.update!(status: 'complained')
        Marketing::EmailSuppression.add!(recipient.email, 'complained')
      when 'SubscriptionChange'
        Marketing::EmailSuppression.add!(recipient.email, 'unsubscribed') if event['SuppressSending']
      end
    end
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end
end
