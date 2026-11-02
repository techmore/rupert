# frozen_string_literal: true

# Who sees and who changes the compliance catalog (F70). Viewing needs stock or
# sales read access; approving products, categories, COAs and register rules is
# the owner's call (settings and inventory write).
module ComplianceAccess
  extend ActiveSupport::Concern

  included do
    helper_method :compliance_editor?, :pos_event_manager?
  end

  private

  def compliance_viewer? = Current.user.active? && !Current.user.employee? && (Current.user.can?('inventory.read') || Current.user.can?('sales.read'))
  def compliance_editor? = Current.user.active? && !Current.user.employee? && Current.user.can?('settings.write') && Current.user.can?('inventory.write')
  def pos_event_manager? = Current.user.active? && !Current.user.employee? && (Current.user.can?('sales.write') || Current.user.can_approve_pos_override?)

  def require_compliance_viewer!
    raise Pundit::NotAuthorizedError unless compliance_viewer?

    skip_authorization # gate: compliance_viewer? (inventory.read or sales.read)
  end

  def require_compliance_editor!
    raise Pundit::NotAuthorizedError unless compliance_editor?

    skip_authorization # gate: compliance_editor? (settings.write and inventory.write)
  end
end
