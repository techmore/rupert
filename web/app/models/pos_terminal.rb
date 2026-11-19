# frozen_string_literal: true

# An extra Dejavoo terminal (its own TPN and SPIn auth key) for one register
# of a store. See the create_pos_terminals migration.
class PosTerminal < ApplicationRecord
  include TenantScoped

  belongs_to :location
  encrypts :credentials_json

  scope :active, -> { where(retired_at: nil) }

  validates :name, presence: true, length: { maximum: 60 }
  validates :register_name, presence: true, length: { maximum: 60 }
  validate do
    unless credentials['tpn'].to_s.match?(Pos::DejavooSpinGateway::TPN) && credentials['auth_key'].to_s.match?(Pos::DejavooSpinGateway::AUTH_KEY)
      errors.add(:base, 'Enter the terminal TPN (10 to 12 letters or digits) and SPIn auth key (8 to 64 letters or digits) exactly as iPOSpays shows them.')
    end
    if retired_at.nil? && location && PosTerminal.active.where(location_id: location_id).where.not(id: id)
        .where('LOWER(register_name) = ?', register_name.to_s.strip.downcase).exists?
      errors.add(:register_name, 'already has a terminal')
    end
    errors.add(:base, 'The store’s main TPN cannot also be an extra terminal.') if location && PosSetting.find_by(location: location)&.credentials&.dig('tpn') == credentials['tpn']
  end
  before_validation { self.register_name = register_name.to_s.strip }

  # The verified, active terminal for this register, or nil for the main TPN.
  def self.for_register(location, register)
    return nil unless register

    active.where(location_id: location.id).where.not(verified_at: nil).find_by('LOWER(register_name) = ?', register.name.to_s.strip.downcase)
  end

  def credentials
    value = JSON.parse(credentials_json.presence || '{}')
    value.is_a?(Hash) ? value : {}
  rescue JSON::ParserError
    {}
  end

  def tpn_hint = "…#{credentials['tpn'].to_s.last(4)}"

  # Ties a checkout to this exact terminal and the store's setup.
  def payment_fingerprint(setting) = Digest::SHA256.hexdigest([setting.payment_fingerprint, 'terminal', id, credentials.sort].to_json)
end
