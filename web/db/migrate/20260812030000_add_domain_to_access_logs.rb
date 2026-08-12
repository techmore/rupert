# frozen_string_literal: true

class AddDomainToAccessLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :access_logs, :domain, :string
  end
end
