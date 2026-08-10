# frozen_string_literal: true

# Audit trail: a chronological log of business actions.
class ActivityController < AuthenticatedController
  def index
    authorize(:module, :settings_read?)
    @activities = ActivityLog.where(tenant_id: Current.tenant_id).recent(200)
  end
end
