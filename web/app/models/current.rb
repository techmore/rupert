# frozen_string_literal: true

# Thread-local context for the current request/job.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :tenant, :sync_run

  def tenant_id
    tenant&.id
  end

  # The SyncRun currently being executed in this thread (background jobs and
  # rake tasks). Mirror movements created during the sync are stamped with it
  # so the ledger can say *which* sync changed a quantity.
  def sync_run_id
    sync_run&.id
  end

  def user=(value)
    super
    self.tenant = value&.tenant
  end
end
