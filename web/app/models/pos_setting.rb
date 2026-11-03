# frozen_string_literal: true

class PosSetting < ApplicationRecord
  include TenantScoped
  belongs_to :location
  belongs_to :production_approved_by, class_name: 'User', optional: true
  encrypts :credentials_json, :webhook_signing_key
  validates :location_id, uniqueness: { scope: :tenant_id }
  # dejavoo_spin: a Dejavoo terminal driven through SPIn cloud. Sandbox only
  # until Dejavoo signs off the integration and the processor issues a
  # production TPN (see docs/integrations/dejavoo-valmar-meeting-brief.md).
  CREDENTIAL_KEYS = {
    'authorize_net' => %w[api_login_id transaction_key],
    'nmi' => %w[security_key tokenization_key merchant_company],
    'dejavoo_spin' => %w[tpn auth_key]
  }.freeze
  validates :gateway_provider, inclusion: { in: CREDENTIAL_KEYS.keys }
  validates :environment, inclusion: { in: %w[sandbox production] }
  validate do
    errors.add(:location, 'must be a C-Trax store in this workspace') unless location&.tenant_id == tenant_id && location.source == 'ctrax'
    if gateway_provider == 'nmi' && environment == 'production' && !production_approved_at
      errors.add(:base, 'NMI production needs owner sign-off: confirm the processor approved this merchant account and record the approval.')
    end
    if production_approved_at && (production_approval_note.to_s.squish.length < 10 || production_approval_note.to_s.length > 1000)
      errors.add(:production_approval_note, 'must say who approved the account and when (10 to 1000 characters)')
    end
    errors.add(:base, 'Sign-off must be recorded by a user in this workspace.') if production_approved_by && production_approved_by.tenant_id != tenant_id
    if webhook_signing_key.present? && !webhook_signing_key.match?(/\A[[:graph:]]{16,256}\z/)
      errors.add(:webhook_signing_key, 'must be the signing key exactly as the gateway shows it')
    end
    errors.add(:environment, 'must be sandbox for Dejavoo terminals until production is enabled') if gateway_provider == 'dejavoo_spin' && environment != 'sandbox'
    if gateway_provider == 'dejavoo_spin' && ((credentials['tpn'] && !credentials['tpn'].to_s.match?(/\A[A-Za-z0-9]{10,12}\z/)) || (credentials['auth_key'] && !credentials['auth_key'].to_s.match?(/\A[A-Za-z0-9]{10}\z/)))
      errors.add(:base, 'Enter the Dejavoo TPN (10 to 12 letters or digits) and auth key (10 letters or digits) exactly as iPOSpays shows them.')
    end
    allowed = CREDENTIAL_KEYS.fetch(gateway_provider, [])
    if credentials.any? { |key, v| !v.is_a?(String) || !(key == 'merchant_company' ? v.match?(/\A[[:print:]]{1,128}\z/) : v.match?(/\A[[:graph:]]{1,128}\z/)) } || (credentials.keys - allowed).any?
      errors.add(:base, 'Enter supported gateway credentials.')
    end
    errors.add(:base, 'Check this gateway before enabling card charges.') if card_enabled && !verified_at
    errors.add(:gateway_id, 'must be a numeric gateway account ID') if gateway_id.present? && !gateway_id.match?(/\A[1-9][0-9]{0,29}\z/)
    if credentials['api_login_id'].to_s.length > 25 || credentials['transaction_key'].to_s.length > 16
      errors.add(:base, 'Gateway API Login ID or Transaction Key is too long.')
    end
    if persisted? && (will_save_change_to_credentials_json? || will_save_change_to_gateway_id? || will_save_change_to_environment? || will_save_change_to_gateway_provider?) && PosCheckout.where(location_id: location_id, tender: 'card', status: %w[processing unknown]).exists?
      errors.add(:base, 'Resolve outstanding card payments before changing the gateway account or credentials.')
    end
  end
  before_validation do
    if will_save_change_to_credentials_json? || will_save_change_to_gateway_id? || will_save_change_to_environment? || will_save_change_to_gateway_provider?
      self.verified_at = nil
      self.public_client_key = nil
      self.card_enabled = false
    end
    # Sign-off covers one account: a new provider, environment or account ID needs it again.
    if persisted? && (will_save_change_to_gateway_id? || will_save_change_to_environment? || will_save_change_to_gateway_provider?) && !will_save_change_to_production_approved_at?
      self.production_approved_at = nil
      self.production_approved_by = nil
      self.production_approval_note = nil
    end
  end
  def nmi_sandbox? = gateway_provider == 'nmi' && environment == 'sandbox'
  def nmi_production? = gateway_provider == 'nmi' && environment == 'production'
  def nmi_ready_environment? = gateway_provider == 'nmi' && (environment == 'sandbox' || production_approved_at.present?)
  def dejavoo_sandbox? = gateway_provider == 'dejavoo_spin' && environment == 'sandbox'

  def payment_fingerprint
    Digest::SHA256.hexdigest([gateway_provider, environment, gateway_id, credentials.sort].to_json)
  end

  def credentials
    value = JSON.parse(credentials_json.presence || '{}')
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end
end
