# frozen_string_literal: true

# Per-tenant, per-role permission overrides. When rows exist for a role, they
# define exactly what that role can do (replacing the built-in defaults); the
# Permissions screen edits these. An empty table means "use the built-in role
# matrix" from User::ROLE_PERMISSIONS.
class RolePermission < ApplicationRecord
  belongs_to :tenant, optional: true

  validates :role, presence: true, inclusion: { in: User.roles.keys }
  validates :permission, presence: true
  validates :permission, uniqueness: { scope: [:tenant_id, :role] }
end
