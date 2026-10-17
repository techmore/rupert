# frozen_string_literal: true

class BankFeedEntry < ApplicationRecord
  include TenantScoped
  encrypts :payload_json
  belongs_to :bank_connection
  belongs_to :bank_statement_line, optional: true
  def payload = JSON.parse(payload_json.presence || '{}')
end
