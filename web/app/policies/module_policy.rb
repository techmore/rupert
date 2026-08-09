# frozen_string_literal: true

# Generic gate for module-level pages (index/sync/etc.) that aren't tied to a
# specific record. Authorize with `authorize :module, :sales_read?` and define
# a method per permission.
class ModulePolicy < ApplicationPolicy
  [
    :dashboard_read,
    :sales_read,
    :sales_write,
    :customers_read,
    :customers_write,
    :inventory_read,
    :inventory_write,
    :reconcile_read,
    :reconcile_write,
    :reports_read,
    :reports_write,
    :ledger_read,
    :ledger_write,
    :projects_read,
    :projects_write,
    :alerts_read,
    :alerts_write,
    :sync_read,
    :sync_write,
    :settings_read,
    :system_read,
  ].each do |perm|
    define_method("#{perm}?") { module?(perm.to_s.tr("_", ".")) }
  end
end
