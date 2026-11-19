# frozen_string_literal: true

module Internal
  # An isolated workspace node asks what its subscription allows (WorkspaceNode.entitlement).
  # Authenticated with the instance's own secret, like the session exchange it inherits from.
  # The route exists only while SelfService is on.
  class WorkspaceEntitlementsController < WorkspaceSessionsController
    def show
      render json: WorkspaceEntitlement.for(@deployment.tenant).as_json
    end
  end
end
