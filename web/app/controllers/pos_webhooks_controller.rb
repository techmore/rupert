# frozen_string_literal: true

require 'openssl'

# Gateway webhooks for a store's POS card setup (F69). A callback authenticates
# itself with the gateway signature over the exact raw body, not a user session.
# Its contents are only a hint: the job rechecks payments and refunds through
# the gateway API and never trusts amounts or status from the callback.
#
# - Authorize.net: X-ANET-Signature: sha512=<HMAC-SHA512 of body with the Signature Key>
# - NMI: Webhook-Signature: t=<nonce>,s=<HMAC-SHA256 of "nonce.body" with the signing key>
#   (docs.nmi.com/reference/overview)
class PosWebhooksController < ActionController::API
  MAX_BYTES = 65_536
  ID = /\A[1-9][0-9]{0,29}\z/

  def create
    response.headers['Cache-Control'] = 'no-store'
    setting = PosSetting.unscoped.find_by(id: request.path_parameters[:setting_id])
    return head(:not_found) unless setting && Tenant.where(id: setting.tenant_id, status: 'active').exists?

    secret = setting.webhook_signing_key.to_s
    return head(:not_found) if secret.blank?
    return head(:content_too_large) if request.content_length.to_i > MAX_BYTES

    body = request.body.read(MAX_BYTES + 1).to_s
    return head(:content_too_large) if body.bytesize > MAX_BYTES

    verified = setting.gateway_provider == 'nmi' ? nmi_signed?(secret, body) : authorize_net_signed?(secret, body)
    return head(:unauthorized) unless verified

    event = JSON.parse(body, max_nesting: 10)
    return head(:bad_request) unless event.is_a?(Hash)

    hint = setting.gateway_provider == 'nmi' ? nmi_hint(event) : authorize_net_hint(event)
    return head(:ok) unless hint # Signed but irrelevant (e.g. a settlement or customer event).

    job = PosWebhookJob.perform_later(tenant_id: setting.tenant_id, setting_id: setting.id, **hint)
    head(job ? :ok : :service_unavailable)
  rescue JSON::ParserError, EncodingError
    head(:bad_request)
  rescue ActiveJob::EnqueueError
    head(:service_unavailable)
  end

  private

  def authorize_net_signed?(secret, body)
    supplied = request.headers['X-ANET-Signature'].to_s
    return false unless supplied.match?(/\Asha512=[0-9a-f]{128}\z/i)

    # The Signature Key is documented as hex; accept the legacy text-key form too.
    keys = secret.match?(/\A(?:[0-9a-f]{2})+\z/i) ? [[secret].pack('H*'), secret] : [secret]
    keys.any? { |key| ActiveSupport::SecurityUtils.secure_compare(OpenSSL::HMAC.hexdigest('SHA512', key, body), supplied.split('=', 2).last.downcase) }
  end

  def nmi_signed?(secret, body)
    match = request.headers['Webhook-Signature'].to_s.match(/\At=([A-Za-z0-9._-]{1,128}),s=([0-9a-f]{64})\z/i)
    return false unless match

    ActiveSupport::SecurityUtils.secure_compare(OpenSSL::HMAC.hexdigest('SHA256', secret, "#{match[1]}.#{body}"), match[2].downcase)
  end

  def authorize_net_hint(event)
    payload = event['payload']
    return nil unless event['eventType'].to_s.start_with?('net.authorize.payment.') && payload.is_a?(Hash) && payload['entityName'] == 'transaction'

    id = payload['id'].to_s
    id.match?(ID) ? { transaction_id: id, order_id: nil } : nil
  end

  def nmi_hint(event)
    body = event['event_body']
    return nil unless event['event_type'].to_s.start_with?('transaction.') && body.is_a?(Hash)

    id = body['transaction_id'].to_s
    order = body['order_id'].to_s
    return nil unless id.match?(ID) || order.match?(/\A[A-Za-z0-9]{1,40}\z/)

    { transaction_id: id.match?(ID) ? id : nil, order_id: order.match?(/\A[A-Za-z0-9]{1,40}\z/) ? order : nil }
  end
end
