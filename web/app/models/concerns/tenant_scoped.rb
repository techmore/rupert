# frozen_string_literal: true

# Scopes a model to the current tenant. When no tenant is in context (e.g.
# setup/onboarding before any tenant exists) the scope returns nothing, which
# keeps stray rows from leaking across tenants.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :tenant, optional: true

    default_scope { where(tenant_id: Current.tenant_id) }
  end
end
