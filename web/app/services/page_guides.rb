# frozen_string_literal: true

# In-app help: "how to use this page" guides keyed by ModuleRegistry key. The
# shell renders PageGuides.for(active_module_entry.key) at the top of each
# module page. Content is written for real usage — what the page shows and how
# to get the most out of it.
class PageGuides
  Guide = Struct.new(:key, :title, :summary, :sections, :tips, keyword_init: true)

  GUIDES = {
    "dashboard" => Guide.new(
      key: "dashboard", title: "Dashboard",
      summary: "Your at-a-glance store health: today's money, sales volume, and anything needing attention like inventory drift or low stock.",
      sections: [
        { heading: "What you're seeing", body: "The top cards summarize today and yesterday: gross revenue, sales volume, and attention items. Charts show the trend over the last 30 days. The attention rail lists real problems — SKUs where Shopify and Square disagree, or items near/out of stock — so you act on the exceptions, not the whole list." },
        { heading: "How to read the numbers", body: "Revenue is gross sales (before returns), from orders mirrored by the sync. Volume is order count, not items. 'vs yesterday' compares the same hour-of-day, so morning vs morning. A red SKU in attention means a reconcile adjustment is waiting." },
      ],
      tips: [
        "Check the attention rail first every morning — it's ordered by severity.",
        "Drill into an out-of-sync SKU on the Reconcile page, don't fix it by hand in Square.",
        "Customize which widgets you see from the customize control, not the code.",
      ],
    ),
    "sales" => Guide.new(
      key: "sales", title: "Sales",
      summary: "The daily sales journal — every sale in arrival order with where it happened, hourly × location, and revenue trends you can split by source.",
      sections: [
        { heading: "What you're seeing", body: "Top row: the selected day's total, average sale, busiest hour, and the window total. The charts show daily revenue and the typical hour-by-hour shape. The 'Hourly × location' table is the storefloor ledger for the day. The bottom list is every sale in arrival order — tap one for the full order." },
        { heading: "The source toggle", body: "All / Shopify / Square switches every number, chart, and table to just that channel — useful to see online vs in-store separately. The choice is in the URL, so you can bookmark a filtered view." },
      ],
      tips: [
        "Use the source toggle to verify a Square outage didn't lose POS sales.",
        "Jump to yesterday (or a specific day) with the date picker to close the previous shift.",
        "Print an invoice or packing slip from this page for the shipping desk.",
      ],
    ),
    "inventory" => Guide.new(
      key: "inventory", title: "Inventory",
      summary: "Your catalog mirrored from Shopify with quantities on both sides — plus size-derived products and a banner when any count is negative.",
      sections: [
        { heading: "What you're seeing", body: "One row per product variant: its Shopify and Square counts and the drift between them. A 'size 5g' badge means the variant derives from a root gram bank and reconciles on the Sizes page, not here. The red banner lists negative counts — oversold or non-inventory SKUs — with one-click corrections." },
        { heading: "How to read the numbers", body: "Drift = Square − Shopify. Positive means Square thinks you have more than Shopify; negative means less. Zero is healthy. Search by product title or SKU; the page shows the first 40 matches." },
      ],
      tips: [
        "When the negative-count banner appears, fix items individually (Set to 0 / Untrack) so you don't guess.",
        "Size-derived SKUs are marked — manage their root grams on the Sizes page, not by editing here.",
        "Unlinked variants (no Square link) show 'unlinked'; run a sync after creating new SKUs to link them.",
      ],
    ),
    "reconcile" => Guide.new(
      key: "reconcile", title: "Reconcile",
      summary: "The bridge between Shopify and Square inventory — see where they disagree, set which side wins, and apply corrections.",
      sections: [
        { heading: "What you're seeing", body: "A row per linked SKU with both counts, the drift, and a priority policy. Below, 'Size families' groups each root product with the sizes derived from it. The pending-approval queue lists size changes waiting to be written." },
        { heading: "How priority works", body: "Priority decides the reconciliation target: 'lowest' takes whichever side has less, 'shopify' trusts Shopify, 'square' trusts Square. The apply button writes the chosen targets to both platforms with a safety preflight." },
      ],
      tips: [
        "Start with 'lowest' for products you physically control; switch to 'square' only when Square is authoritative.",
        "Size-derived SKUs are excluded here on purpose — they're handled by the root gram math on the Sizes page.",
        "Review the pending size queue and approve it in one click when the math looks right.",
      ],
    ),
    "sizes" => Guide.new(
      key: "sizes", title: "Sizes",
      summary: "Multi-size gram products derived from a root gram bank. Every 15-minute sync folds in sales and recomputes each size as floor(root grams ÷ size grams).",
      sections: [
        { heading: "What you're seeing", body: "Each family card shows its root gram bank (the source of truth) and every size with current vs derived target. 'Pending approvals' lists recomputed sizes awaiting your sign-off before they're written to Square." },
        { heading: "Root grams & modes", body: "Set root grams after a physical count — it's the number every size derives from. 'Approval-only' queues changes for review; 'auto-apply' writes them every sync. A size showing 'in sync' needs nothing." },
      ],
      tips: [
        "After a physical count of the flower, hit 'Set root grams' — it resets the sales watermark so prior sales aren't double-counted.",
        "Keep families on approval-only until you trust the math, then flip to auto.",
        "Approve pending sizes in one click; rejected math shows as 'failed' with the reason.",
      ],
    ),
    "warehouse" => Guide.new(
      key: "warehouse", title: "Warehouse",
      summary: "Wholesale pages for vendors — secret links with a negotiated price multiplier and bulk discount tiers.",
      sections: [
        { heading: "What you're seeing", body: "Global bulk tiers apply to every vendor by default; each vendor link can override them with custom tiers. The vendor's page shows list price, their multiplier, and a per-tier price breakdown at 10+, 25+, etc." },
        { heading: "How pricing works", body: "Vendor price = list × multiplier, then bulk tiers stack a % off at quantity thresholds. The link token in the URL is the only access control — share it privately." },
      ],
      tips: [
        "Create one link per customer and set their negotiated multiplier (e.g. 0.85 = 15% off list).",
        "Set custom bulk tiers per vendor when one customer's deal differs from the global schedule.",
        "Deactivate a link (not delete) when a customer relationship pauses — the URL stops working instantly.",
      ],
    ),
    "activity" => Guide.new(
      key: "activity", title: "Activity",
      summary: "The audit trail — who did what, to which record, and when.",
      sections: [
        { heading: "What you're seeing", body: "A chronological log of business actions: employee changes, permission edits, and other write operations with the actor and the record they touched." },
      ],
      tips: [
        "Pair this with the Access log — Activity is what happened in the app, Access log is who signed in from where.",
      ],
    ),
    "access_log" => Guide.new(
      key: "access_log", title: "Access log",
      summary: "Every sign-in attempt — who tried, from which IP, when, and whether it worked — so you can spot brute force or unwanted access.",
      sections: [
        { heading: "What you're seeing", body: "One row per authentication event: the person (or attempted email), the domain they tried, the method (password / Google / sign-out), status, IP address, and a reason for failures (unknown email, bad password, domain not allowed, rate limited)." },
        { heading: "Reading failures", body: "A spike of 'failure' rows from one IP means someone is guessing passwords. Repeated rows for one email mean that account is being targeted — the login throttle auto-blocks after 10 per IP / 5 per email in 15 minutes." },
      ],
      tips: [
        "Filter by Status = failure and look at the IP column to spot attackers.",
        "The 'attempt' rows are Google sign-ins that started but may have been cancelled before completing.",
        "Rate-limited attempts are logged but don't extend the lockout.",
      ],
    ),
    "sync" => Guide.new(
      key: "sync", title: "Sync",
      summary: "Pull Shopify + Square into Rupert. Runs automatically every 15 minutes; here you can run it manually and see the history.",
      sections: [
        { heading: "What you're seeing", body: "The last sync runs with status and drift. Manual controls let you trigger a full sync or just one source (Shopify or Square) — useful after you change a SKU or fix inventory in one platform." },
      ],
      tips: [
        "After creating products/SKUs in Shopify or Square, run a sync so the links appear.",
        "A failed sync shows the error here — most are transient; the next scheduled run recovers.",
      ],
    ),
    "settings" => Guide.new(
      key: "settings", title: "Settings",
      summary: "Your store's configuration — business details, Google sign-in, size families, warehouse links, Drive backups, and the Buzz agent.",
      sections: [
        { heading: "What's here", body: "Business name and invoice prefix; Google OAuth (allowed domains + client credentials); size families (root gram products); the wholesale Warehouse link; Google Drive backup connection; and the Buzz agent identity." },
      ],
      tips: [
        "Connect Google Drive here to enable off-site backups — Rupert dumps your database every 6 hours.",
        "Add every staff email domain to Google sign-in; new people on an allowed domain get a reader account automatically.",
        "Environment secrets (Square/Shopify tokens) live in the .env card and are encrypted at rest.",
      ],
    ),
    "employees" => Guide.new(
      key: "employees", title: "Employees",
      summary: "Your team directory — who works where, linked to their login accounts.",
      sections: [
        { heading: "What you're seeing", body: "Every employee with their role/position and, where set, the login account they use to sign in. Roles drive what each person can see and do." },
      ],
      tips: [
        "Link an employee to a login account so their work (timesheets, sales) is attributed to them.",
        "Manage what they can access on the Permissions screen, not by editing the role matrix directly.",
      ],
    ),
    "timesheets" => Guide.new(
      key: "timesheets", title: "Timesheets",
      summary: "Clock-in tracking for the team — time worked per employee and shift.",
      sections: [
        { heading: "What you're seeing", body: "Timesheet entries with in/out times, submitted, reviewed, and approved states. Approvals feed payroll." },
      ],
      tips: [
        "Review and approve on the day or week — it keeps payroll smooth and disputes rare.",
      ],
    ),
    "payroll" => Guide.new(
      key: "payroll", title: "Payroll",
      summary: "Run pay periods from approved time — draft runs, finalize, and generate payslips.",
      sections: [
        { heading: "What you're seeing", body: "Pay runs built from approved timesheets, with finalize and payslip steps. Drafts are editable; finalized runs are locked." },
      ],
      tips: [
        "Only approved hours flow into a pay run — approve timesheets first.",
      ],
    ),
    "users" => Guide.new(
      key: "users", title: "Accounts",
      summary: "Who can sign in and their role. Also the per-person permission overrides.",
      sections: [
        { heading: "What you're seeing", body: "The login accounts (which pair with employees) and their roles: super_admin, admin, manager, cashier, reader. Super admin is platform-wide; everything else is scoped to this store." },
      ],
      tips: [
        "Give the least privilege that works — readers can view, managers can run, admins configure.",
        "Use per-person overrides sparingly; role defaults keep things predictable.",
      ],
    ),
    "permissions" => Guide.new(
      key: "permissions", title: "Permissions",
      summary: "The catalog of every permission in the system and how roles map to them.",
      sections: [
        { heading: "What you're seeing", body: "Every capability grouped by area (Sales, Inventory, System, Team). Role overrides let you change what a role can do store-wide, and per-employee overrides on the Accounts page fine-tune one person." },
      ],
      tips: [
        "An override replaces the role's built-ins for that person — keep the list complete when you add one.",
      ],
    ),
    "finance" => Guide.new(
      key: "finance", title: "Finance",
      summary: "Chart of accounts, expenses, and vendor payments — the books that tie sales to money out.",
      sections: [
        { heading: "What you're seeing", body: "Your chart of accounts, expense records, and vendor payments. Expense entries keep inventory cost and overhead separated so reports reflect true margin." },
      ],
      tips: [
        "Keep the chart of accounts tidy — reports read straight from it.",
      ],
    ),
    "purchasing" => Guide.new(
      key: "purchasing", title: "Purchasing",
      summary: "Vendors and purchase orders — what you buy and what you've received.",
      sections: [
        { heading: "What you're seeing", body: "A vendor list and purchase orders with placed → received → cancelled states. Receiving a PO moves goods into inventory." },
      ],
      tips: [
        "Receive POs promptly so inventory reflects stock arriving, not just sales leaving.",
      ],
    ),
    "reports" => Guide.new(
      key: "reports", title: "Reports",
      summary: "Financial and operational reports — sales, money, inventory, and operations.",
      sections: [
        { heading: "What you're seeing", body: "Report views for sales, financials, inventory, and operations, pulled from the mirrored data. Export options let you take numbers to spreadsheets." },
      ],
      tips: [
        "Run a sync first so reports always use the freshest data.",
      ],
    ),
    "ledger" => Guide.new(
      key: "ledger", title: "Ledger",
      summary: "Every money movement in and out — the source of truth for financials.",
      sections: [
        { heading: "What you're seeing", body: "Ledger entries built from sales and expenses: gross, payments, refunds. Reconcile totals against your bank to catch discrepancies." },
      ],
      tips: [
        "Drill into any entry to see the originating order or expense.",
      ],
    ),
    "alerts" => Guide.new(
      key: "alerts", title: "Alerts",
      summary: "Low-stock and exception alerts so you restock before you're out.",
      sections: [
        { heading: "What you're seeing", body: "Stock alerts per SKU with the current count vs threshold, plus open/resolved status so you can track follow-through." },
      ],
      tips: [
        "Resolve alerts as you reorder — open alerts are the work queue.",
      ],
    ),
    "customers" => Guide.new(
      key: "customers", title: "Customers",
      summary: "Everyone who buys — orders, contact info, and history in one place.",
      sections: [
        { heading: "What you're seeing", body: "The customer list, searchable, with their order history. Opening a customer shows the orders they've placed across channels." },
      ],
      tips: [
        "Search by name, phone, or email — not just order number.",
      ],
    ),
    "connections" => Guide.new(
      key: "connections", title: "Connections",
      summary: "The integrations powering Rupert — Shopify, Square, Google Drive, Buzz — and their status.",
      sections: [
        { heading: "What you're seeing", body: "Each connected service and whether it's healthy. Reconnect or check credentials here when a sync fails." },
      ],
      tips: [
        "If a sync fails, check Connections first — it's usually a revoked token, not a code bug.",
      ],
    ),
    "system" => Guide.new(
      key: "system", title: "System",
      summary: "Health and diagnostics for the app itself.",
      sections: [
        { heading: "What you're seeing", body: "Runtime info and diagnostics to confirm the system is healthy and which version is running." },
      ],
      tips: [
        "Reference the version here when reporting an issue.",
      ],
    ),
  }.freeze

  # Path prefix -> guide key, most-specific first. Matched by the shell so help
  # appears automatically on the right page regardless of module-registry keys.
  PATH_MAP = [
    ["/size_families", "sizes"],
    ["/access_logs", "access_log"],
    ["/finance", "finance"],
    ["/purchasing", "purchasing"],
    ["/sales", "sales"],
    ["/inventory", "inventory"],
    ["/reconcile", "reconcile"],
    ["/warehouse", "warehouse"],
    ["/activity", "activity"],
    ["/syncs", "sync"],
    ["/settings", "settings"],
    ["/employees", "employees"],
    ["/timesheets", "timesheets"],
    ["/pay_runs", "payroll"],
    ["/users", "users"],
    ["/permissions", "permissions"],
    ["/reports", "reports"],
    ["/ledger", "ledger"],
    ["/alerts", "alerts"],
    ["/customers", "customers"],
    ["/connections", "connections"],
    ["/system", "system"],
  ].freeze

  class << self
    def for(key)
      GUIDES[key.to_s]
    end

    def for_path(path)
      return GUIDES["dashboard"] if path.to_s == "/"

      match = PATH_MAP.find { |prefix, _| path.to_s.start_with?(prefix) }
      match && GUIDES[match.last]
    end

    def keys
      GUIDES.keys
    end
  end
end
