# frozen_string_literal: true

# Per-employee permission overrides. When rows exist for a user, they define
# exactly what that person can do, layered on top of (and able to override)
# their role. The employee edit screen manages these; an empty set means "use
# the role's permissions".
class UserPermission < ApplicationRecord
  belongs_to :user, optional: true

  validates :permission, presence: true
  validates :permission, uniqueness: { scope: [:tenant_id, :user_id] }
end
