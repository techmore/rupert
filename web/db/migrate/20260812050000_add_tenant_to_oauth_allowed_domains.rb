# frozen_string_literal: true

# Scope the Google sign-in allow-list to a tenant so one store's domain list
# can't be edited by another. Existing rows (added before tenancy) are claimed
# by the oldest tenant; a super admin can re-attribute them from the DB.
class AddTenantToOauthAllowedDomains < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_allowed_domains, :tenant_id, :string

    reversible do |dir|
      dir.up do
        first_tenant = Tenant.order(:created_at).first
        next if first_tenant.nil?

        execute <<~SQL.squish
          UPDATE oauth_allowed_domains SET tenant_id = '#{first_tenant.id}'
          WHERE tenant_id IS NULL
        SQL
      end
    end

    remove_index :oauth_allowed_domains, :domain
    add_index :oauth_allowed_domains, %i[tenant_id domain], unique: true
  end
end
