# frozen_string_literal: true

# Read-only summary of what each role allows, for the Permissions page.
#
# Every cell is answered by the authorization code itself: for each role we
# build an unsaved sample account in this business and ask it the same
# questions the app asks (User#can?, #can_use_pos?, #can_review_timesheets?
# and so on). The role's built-in list, this business's role changes and the
# fixed staff boundary all apply exactly as they do at sign-in. Per-person
# overrides do not, because they belong to a person, not a role.
#
# This file only adds words: a business area and one plain sentence per
# permission. A permission with no sentence still appears (under its catalog
# area), and a test fails until it gets one.
class RoleAccessGrid
  Row = Struct.new(:key, :label, :description, :code, keyword_init: true)
  Area = Struct.new(:name, :rows, keyword_init: true)

  # Permission => [business area, short label, what it allows].
  # Areas follow ModuleRegistry sections so they read like the rail.
  PERMISSIONS = {
    'dashboard.read' => ['Overview', 'Dashboard', "Open the dashboard with the day's figures and work queues."],
    'chat.use' => ['Overview', 'Ask Rupert', 'Ask the in-app assistant questions about the business.'],

    'pos.use' => ['Sell', 'POS only', 'Ring up sales at the POS without seeing sales history or reports.'],
    'sales.read' => ['Sell', 'See sales', 'See sales, registers and daily closes.'],
    'sales.write' => ['Sell', 'Edit sales', 'Open and close registers, record shipments and release warehouse stock for orders.'],
    'customers.read' => ['Sell', 'See customers', 'See customer records and their purchase history.'],
    'customers.write' => ['Sell', 'Edit customers', 'Add and edit customers.'],

    'marketing.read' => ['Marketing', 'See marketing', 'See campaigns, events and influencers.'],
    'marketing.write' => ['Marketing', 'Edit marketing', 'Draft and edit campaigns, events and influencer work.'],
    'marketing.review' => ['Marketing', 'Approve marketing', 'Approve or send back marketing content before it goes out.'],
    'marketing.contacts' => ['Marketing', 'Private contacts', 'See private contact and shipping details and restricted documents.'],
    'marketing.discounts' => ['Marketing', 'Discount codes', 'Create discount codes for campaigns.'],

    'inventory.read' => ['Stock', 'See stock', 'See stock levels, counts, transfers and movements.'],
    'inventory.write' => ['Stock', 'Change stock', 'Adjust stock, record counts, reserve stock and move it between locations.'],
    'alerts.read' => ['Stock', 'See stock alerts', 'See low-stock and other stock alerts.'],
    'alerts.write' => ['Stock', 'Handle stock alerts', 'Resolve and dismiss stock alerts.'],
    'reconcile.read' => ['Stock', 'See catalog links', 'See how products are linked across sales channels.'],
    'reconcile.write' => ['Stock', 'Edit catalog links', 'Link and unlink products across sales channels.'],
    'purchasing.read' => ['Stock', 'See purchasing', 'See vendors and purchase orders.'],
    'purchasing.write' => ['Stock', 'Edit purchasing', 'Add and edit vendors and purchase orders.'],

    'finance.read' => ['Bookkeeping', 'See the books', 'See bank transactions, expenses, the ledger and financial statements.'],
    'finance.write' => ['Bookkeeping', 'Keep the books', 'Record expenses, sort bank transactions, post journal entries and review receipts.'],
    'receipts.review' => ['Bookkeeping', 'Review receipts', 'Review purchase receipts that staff upload.'],
    'ledger.read' => ['Bookkeeping', 'See imported orders', 'See orders imported from sales channels and QuickBooks.'],
    'ledger.write' => ['Bookkeeping', 'Approve imports', 'Approve or reverse imported batches such as a QuickBooks import.'],
    'tax.read' => ['Bookkeeping', 'See tax records', 'See 1099 payees and tax records.'],
    'tax.write' => ['Bookkeeping', 'Edit tax records', 'Edit 1099 payees and tax records.'],

    'reports.read' => ['Reports', 'See reports', 'Open reports, daily reconciliation and close & review.'],
    'reports.write' => ['Reports', 'Close and review', 'Close days, lock periods, approve the books and follow up on gaps.'],

    'projects.read' => ['Work', 'See projects', 'See projects, tasks, goals and KPIs.'],
    'projects.write' => ['Work', 'Edit projects', 'Add and edit projects, tasks, goals and KPIs, and handle requests.'],
    'tasks.self' => ['Work', 'Own tasks', 'See and update only the tasks assigned to them.'],

    'timesheets.self' => ['Team and time', 'Own time records', 'Clock in and out, and keep their own timesheets and time off.'],
    'timesheets.read' => ['Team and time', "See everyone's time", 'See all timesheets, punches and the team schedule.'],
    'timesheets.write' => ['Team and time', "Edit everyone's time", 'Edit and reopen anyone\'s timesheet.'],
    'timesheets.review' => ['Team and time', 'Review timesheets', "Approve or reject timesheets without editing them. Edit everyone's time already allows it."],
    'schedule.write' => ['Team and time', 'Build the schedule', 'Add and change scheduled shifts.'],
    'leave.read' => ['Team and time', 'See time off', 'See time-off requests and balances.'],
    'leave.write' => ['Team and time', 'Approve time off', 'Approve, deny and edit time-off requests.'],
    'hr.read' => ['Team and time', 'See staff records', 'See staff records, positions, departments and training.'],
    'hr.write' => ['Team and time', 'Edit staff records', 'Add and edit staff, positions, departments and training.'],
    'users.read' => ['Team and time', 'See user accounts', 'See user accounts and this Permissions page.'],
    'users.write' => ['Team and time', 'Edit user accounts', 'Add, edit and deactivate accounts (administrators only).'],

    'payroll.read' => ['Payroll', 'See payroll', 'See pay runs, payslips, pay rates and commissions.'],
    'payroll.write' => ['Payroll', 'Run payroll', 'Run and edit pay runs, change pay rates and approve clock corrections.'],

    'settings.read' => ['System', 'See settings', 'See settings, connections, activity and the access log.'],
    'settings.write' => ['System', 'Change settings', 'Change settings and connections, Team chat and API access.'],
    'sync.read' => ['System', 'See sync status', 'See when each connected source last synced.'],
    'sync.write' => ['System', 'Sync now', 'Start a sync from a connected source.'],
    'system.read' => ['System', 'See system health', 'See system health and recent errors.'],
    'system.write' => ['System', 'Run updates', 'Install updates and run maintenance on this instance.'],
    'uploads.read' => ['System', 'See uploads', 'See files in the uploads inbox.'],
    'uploads.write' => ['System', 'Upload files', 'Add files to the uploads inbox.']
  }.freeze

  AREA_ORDER = ['Key abilities', 'Overview', 'Sell', 'Marketing', 'Stock', 'Bookkeeping', 'Reports', 'Work',
                'Team and time', 'Payroll', 'System'].freeze

  # Abilities people ask about, each built from several permissions. The
  # lambdas call the same User methods the controllers and policies call.
  ABILITIES = [
    ['manage_accounts', 'Manage accounts and roles', 'Add users, change roles and edit permissions.',
     ->(user) { user.role_allows_account_management? }],
    ['use_pos', 'Use the POS', 'Ring up sales at the register.', ->(user) { user.can_use_pos? }],
    ['review_timesheets', 'Review timesheets', "Approve or reject other people's timesheets, never their own.",
     ->(user) { user.can_review_timesheets? }],
    ['approve_clock_corrections', 'Approve clock corrections',
     "Approve or reject changes to other people's clock-in and clock-out times, never their own.",
     ->(user) { user.can_approve_clock_corrections? }],
    ['approve_time_off', 'Approve time off', 'Approve or deny time-off requests.', ->(user) { user.can?('leave.write') }],
    ['see_payroll', 'See payroll', 'See pay runs, payslips and pay rates.', ->(user) { user.can?('payroll.read') }],
    ['review_receipts', 'Review receipts', 'Review purchase receipts that staff upload.',
     ->(user) { user.can_review_receipts? }]
  ].freeze

  attr_reader :tenant_id

  def initialize(tenant_id:)
    @tenant_id = tenant_id
  end

  def roles
    User.roles.keys
  end

  def role_label(role)
    role.to_s.humanize
  end

  # Roles this business has changed from the built-in list.
  def changed_roles
    @changed_roles ||= RolePermission.where(tenant_id: tenant_id).distinct.pluck(:role) - %w[super_admin employee]
  end

  def changed?(role)
    changed_roles.include?(role.to_s)
  end

  # Accounts in this business with a personal permission list.
  def personal_override_count
    User.where(tenant_id: tenant_id).joins(:user_permissions).distinct.count
  end

  def areas
    @areas ||= begin
      grouped = Hash.new { |hash, key| hash[key] = [] }
      grouped['Key abilities'] = ABILITIES.map { |key, label, text, _| Row.new(key: key, label: label, description: text) }
      User.permission_catalog.each do |group|
        group[:permissions].each do |permission|
          area, label, text = PERMISSIONS[permission]
          grouped[area || group[:area]] << Row.new(key: permission, code: permission,
            label: label || permission.split('.').last.humanize, description: text || "Part of #{group[:area]}.")
        end
      end
      order = ->(name) { AREA_ORDER.index(name) || AREA_ORDER.length }
      grouped.sort_by { |name, _| [order.call(name), name] }.map { |name, rows| Area.new(name: name, rows: rows) }
    end
  end

  def rows
    areas.flat_map(&:rows)
  end

  def allowed?(role, key)
    answers.fetch(role.to_s).fetch(key)
  end

  private

  def answers
    @answers ||= roles.to_h do |role|
      user = sample_user(role)
      abilities = ABILITIES.to_h { |key, _, _, check| [key, !!check.call(user)] }
      permissions = User.all_permissions.to_h { |permission| [permission, user.can?(permission)] }
      [role, abilities.merge(permissions)]
    end
  end

  # An unsaved, active account with this role in this business: no personal
  # overrides, so it resolves exactly like a newly assigned role.
  def sample_user(role)
    User.new(role: role, tenant_id: tenant_id, active: true)
  end
end
