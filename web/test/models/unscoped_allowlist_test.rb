# frozen_string_literal: true

require 'test_helper'

# `.unscoped` on a TenantScoped model drops the workspace filter along with every other
# default scope. Code that needs discarded, merged or other hidden rows of one workspace
# uses `tenant_unscoped(tenant_id)` (TenantScoped), `with_discarded` (Discard) or
# `including_merged` (People::Employee) instead, all of which keep the tenant filter.
#
# A file may call `.unscoped` only if it is listed here with the reason it must cross
# workspaces or has no workspace (platform rows, token lookups before a tenant is known,
# background sweeps that then set Current.tenant per row). `Tenant.unscoped` is not
# counted: Tenant is the workspace itself, not a tenant-scoped row.
class UnscopedAllowlistTest < ActiveSupport::TestCase
  ALLOWED = {
    'app/controllers/authorize_net_webhooks_controller.rb' => 'webhook resolves its connection (and tenant) by id before any sign-in',
    'app/controllers/concerns/warehouse_portal.rb' => 'public share link resolves its workspace by token',
    'app/controllers/customer_displays_controller.rb' => 'customer display resolves its session by token digest',
    'app/controllers/employee_access_controller.rb' => 'revokes every app session of the grant’s user',
    'app/controllers/oauth_controller.rb' => 'sign-in maps an email domain to candidate workspaces',
    'app/controllers/settings_controller.rb' => 'platform backup log (tenant_id NULL)',
    'app/health/readiness_check.rb' => 'instance health reads sync runs across workspaces',
    'app/jobs/ask_rupert_reply_job.rb' => 'job loads its message by id, then sets the tenant from it',
    'app/jobs/ctrax_sales_sync_job.rb' => 'scheduler sweeps connections across workspaces',
    'app/jobs/ctrax_stock_sync_job.rb' => 'scheduler sweeps connections across workspaces',
    'app/jobs/github_issue_post_job.rb' => 'job loads its feedback by id',
    'app/jobs/iris_daily_deposits_web_job.rb' => 'scheduler sweeps connections across workspaces',
    'app/jobs/pos_inventory_job.rb' => 'sweeps pending stock allocations across workspaces',
    'app/jobs/pos_payment_reconciliation_job.rb' => 'sweeps unsettled payment attempts across workspaces',
    'app/jobs/swipesimple_web_sync_job.rb' => 'scheduler sweeps connections across workspaces',
    'app/jobs/team_chat/attachment_drive_job.rb' => 'job loads its attachment by id',
    'app/jobs/team_chat/recover_runs_job.rb' => 'recovers interrupted runs across workspaces',
    'app/jobs/team_chat/reply_job.rb' => 'job loads its reply by id',
    'app/models/api_access_token.rb' => 'bearer token lookup by digest before a tenant is known',
    'app/models/authorize_net_portal_observation.rb' => 'bulk rewrite/subquery scoped by export id',
    'app/models/concerns/customer_workspace_associations.rb' => 'includes User (not TenantScoped); tenant_id passed explicitly',
    'app/models/employee_access_grant.rb' => 'grant token lookup by digest before a tenant is known',
    'app/models/employee_app_session.rb' => 'session token lookup by digest before a tenant is known',
    'app/models/team_chat/run.rb' => 'run claims/leases by id across processes',
    'app/models/training_assignment.rb' => 'overrides unscoped to keep the training kind',
    'app/models/warehouse_share.rb' => 'WarehouseTier uses a tenantId column, passed explicitly',
    'app/models/workspace_signup.rb' => 'a domain may belong to only one workspace on the instance',
    'app/modules/people/employee.rb' => 'includes User (not TenantScoped); tenant_id passed explicitly',
    'app/services/books_check.rb' => 'platform backup log (tenant_id NULL)',
    'app/services/catalog_syncer.rb' => 'guard: refuses Shopify ids owned by another workspace',
    'app/services/google_drive_backup_service.rb' => 'platform backup log (tenant_id NULL)',
    'app/services/host_vitals.rb' => 'platform backup log (tenant_id NULL)',
    'app/services/instance_overview.rb' => 'super-admin instance totals across workspaces',
    'app/services/ledger_importer.rb' => 'guard: skips ledger ids owned by another workspace',
    'app/services/mcp/tools/backup_freshness.rb' => 'platform backup log (tenant_id NULL)',
    'app/services/mcp/tools/customer_insights.rb' => 'outer query over an already tenant-scoped subquery',
    'app/services/period_close_checklist.rb' => 'platform backup log (tenant_id NULL)',
    'app/services/sensitive_field_encryption.rb' => 'maintenance re-encryption of every row',
    'app/services/source_health.rb' => 'platform backup log / attempts (tenant_id NULL)',
    'app/services/source_sync_status.rb' => 'platform backup log (tenant_id NULL)',
    'app/services/square_syncer.rb' => 'guard: refuses Square ids owned by another workspace',
    'app/services/sync_observability.rb' => 'job hooks record attempts with explicit tenant context',
    'app/services/team_chat/execution.rb' => 'run leases by id across processes',
    'app/services/team_chat/telemetry_recorder.rb' => 'telemetry rows by run id with explicit tenant'
  }.freeze

  test 'unscoped is only called from allowlisted files' do
    root = Rails.root
    offenders = Dir[root.join('{app,lib,config}/**/*.rb')].filter_map do |path|
      relative = Pathname(path).relative_path_from(root).to_s
      next if relative == 'app/models/concerns/tenant_scoped.rb'

      hits = File.readlines(path).reject { |line| line.lstrip.start_with?('#') }
        .select { |line| line.gsub(/Tenant\.unscoped|tenant_unscoped/, '').match?(/\bunscoped\b/) }
      relative if hits.any?
    end.sort
    unexpected = offenders - ALLOWED.keys
    assert_empty unexpected, "New .unscoped call(s) in #{unexpected.join(', ')}. Use tenant_unscoped / with_discarded / " \
      'including_merged to keep the workspace filter, or add the file to ALLOWED with the reason it must cross workspaces.'
    stale = ALLOWED.keys - offenders
    assert_empty stale, "Remove #{stale.join(', ')} from ALLOWED: it no longer calls .unscoped."
  end

  test 'tenant-keeping helpers keep the workspace filter' do
    tenant = tenants(:default_tenant)
    other = Tenant.create!(name: 'Other shop', subdomain: 'unscoped-other', status: 'active')
    Current.set(tenant: tenant) do
      mine = Finance::Expense.create!(payee: 'Mine', category: 'supplies', amount_cents: 500, incurred_on: Date.current)
      mine.discard!
      theirs = Current.set(tenant: other) do
        Finance::Expense.create!(payee: 'Theirs', category: 'supplies', amount_cents: 700, incurred_on: Date.current).tap(&:discard!)
      end
      assert_equal [mine.id], Finance::Expense.with_discarded.where(id: [mine.id, theirs.id]).pluck(:id)
      assert_equal [mine.id], Finance::Expense.tenant_unscoped.where(id: [mine.id, theirs.id]).pluck(:id)
      assert_equal [theirs.id], Finance::Expense.tenant_unscoped(other.id).where(id: [mine.id, theirs.id]).pluck(:id)

      primary = People::Employee.create!(first_name: 'Pat', last_name: 'Primary')
      merged = People::Employee.create!(first_name: 'Pat', last_name: 'Dup')
      merged.update_columns(merged_into_id: primary.id)
      foreign = Current.set(tenant: other) do
        People::Employee.create!(first_name: 'Oz', last_name: 'Other').tap { |row| row.update_columns(merged_into_id: row.id) }
      end
      assert_not People::Employee.exists?(merged.id)
      assert_includes People::Employee.including_merged.pluck(:id), merged.id
      assert_not_includes People::Employee.including_merged.pluck(:id), foreign.id
    end
  end
end
