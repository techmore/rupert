# frozen_string_literal: true

# Scopes a model to the current tenant. When no tenant is in context (e.g.
# setup/onboarding before any tenant exists) the scope returns nothing, which
# keeps stray rows from leaking across tenants.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :tenant, optional: true

    default_scope { where(tenant_id: Current.tenant_id) }

    # Attribution on write is enforced here rather than by each controller
    # remembering to set tenant_id. Explicit values (background jobs, fixtures,
    # cross-tenant imports) are never overridden.
    before_validation :assign_tenant, on: :create
  end

  private

  def assign_tenant
    self.tenant_id = Current.tenant_id if tenant_id.blank?
  end
end
