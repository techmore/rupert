# frozen_string_literal: true

# Per-store register rules (F70). With `locked_catalog` on, the store's cashier
# sells only owner-approved catalog items under their compliant names, and every
# checkout passes Compliance::CartCheck. Event registers are always locked.
class CompliancePolicy < ApplicationRecord
  include TenantScoped

  DEFAULT_COA_MAX_AGE_DAYS = 365

  belongs_to :location

  validates :location_id, uniqueness: { scope: :tenant_id }
  validates :coa_max_age_days, numericality: { only_integer: true, in: 30..1095 }
  validate { errors.add(:base, 'Policy belongs to another workspace.') if location && location.tenant_id != tenant_id }

  # The saved policy, or the unlocked default (unsaved) for a store without one.
  def self.for(location)
    return new(locked_catalog: false, coa_max_age_days: DEFAULT_COA_MAX_AGE_DAYS) unless location

    find_by(location_id: location.id) || new(location: location, locked_catalog: false, coa_max_age_days: DEFAULT_COA_MAX_AGE_DAYS)
  end

  # Event registers always enforce the approved catalog, whatever the store does.
  def self.for_event(location) = self.for(location).dup.tap { |policy| policy.locked_catalog = true }
end
