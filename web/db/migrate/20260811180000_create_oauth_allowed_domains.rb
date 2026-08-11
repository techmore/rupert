# frozen_string_literal: true

class CreateOauthAllowedDomains < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_allowed_domains do |t|
      t.string :domain, null: false
      t.timestamps
    end
    add_index :oauth_allowed_domains, :domain, unique: true
  end
end
