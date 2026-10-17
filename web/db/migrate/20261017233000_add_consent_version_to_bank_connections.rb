# frozen_string_literal: true

class AddConsentVersionToBankConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :bank_connections, :consent_version, :integer, default: 0, null: false
  end
end
