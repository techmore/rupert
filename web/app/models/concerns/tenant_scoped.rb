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

  class_methods do
    # Every default scope removed except the workspace filter: rows the model's other
    # default scopes hide (discarded, merged, ...), but only from +tenant_id+. Use it
    # instead of `unscoped.where(tenant_id: ...)`, which is one typo from reading
    # every workspace. Prefer a model's named helper (with_discarded, including_merged)
    # when only one extra scope should be lifted.
    def tenant_unscoped(tenant_id = Current.tenant_id)
      unscoped.where(tenant_id: tenant_id)
    end
  end

  private

  def assign_tenant
    self.tenant_id = Current.tenant_id if tenant_id.blank?
  end
end
