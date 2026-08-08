# frozen_string_literal: true

# Thread-local context for the current request/job.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :tenant

  def tenant_id
    tenant&.id
  end

  def user=(value)
    super
    self.tenant = value&.tenant
  end
end
