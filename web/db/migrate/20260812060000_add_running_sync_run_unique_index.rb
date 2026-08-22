# frozen_string_literal: true

# Enforce one running sync per tenant at the database level. The application's
# check-then-act guard (running? then insert) could race across SolidQueue
# threads; this partial unique index turns a duplicate insert into a
# RecordNotUnique that the engine can recover from. Only one "running" row may
# exist per tenant at a time.
class AddRunningSyncRunUniqueIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index '"SyncRun"', :tenant_id,
              name: 'index_SyncRun_on_running_per_tenant',
              where: "status = 'running'",
              unique: true,
              algorithm: :concurrently
  end

  def down
    remove_index '"SyncRun"', name: 'index_SyncRun_on_running_per_tenant'
  end
end
