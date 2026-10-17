# frozen_string_literal: true

class BankConnection < ApplicationRecord
  include TenantScoped
  encrypts :credentials_json, :access_token, :cursor
  attr_readonly :tenant_id
  validates :tenant_id, presence: true, uniqueness: true
  validates :environment, inclusion: { in: %w[sandbox production] }
  validate do
    values = credentials
    errors.add(:base, 'Use valid Plaid credentials of at most 512 characters.') unless values.is_a?(Hash) &&
      values.keys.all? { |key| %w[client_id secret].include?(key) } &&
      values.values.all? { |value| value.is_a?(String) && value.bytesize.between?(1, 512) && !value.match?(/[\s\x00-\x1f]/) }
  rescue JSON::ParserError
    errors.add(:base, 'Invalid Plaid credentials.')
  end

  def credentials = JSON.parse(credentials_json.presence || '{}')
  def configured? = credentials.values_at('client_id', 'secret').all?(&:present?)
  def connected? = access_token.present? && item_id.present?
  def client = BankFeed::PlaidClient.new(self)
end
