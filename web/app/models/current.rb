# frozen_string_literal: true

# Thread-local context for the current request/job.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :tenant, :sync_run, :metadata

  def metadata
    super || self.metadata = {}
  end

  def tenant_id
    tenant&.id
  end

  # Explicit platform-write confirmation, set by a controller action only
  # AFTER the user has clicked through a confirmation prompt. See
  # PlatformPushGuard.authorize! — without this (or PUSH_CONFIRM=yes in ops
  # contexts) outbound Shopify/Square writes are refused.
  def push_confirmed?
    metadata[:push_confirmed] == true
  end

  def confirm_push!
    metadata[:push_confirmed] = true
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
