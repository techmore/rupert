# frozen_string_literal: true

# Central registry of Rupert ERP modules. New extensions register here so the
# nav, permission checks, and dashboard widgets all pick them up automatically.
#
# A module entry:
#   key:        unique string used in routes/permissions
#   name:       human label shown in the nav
#   path:       a lambda returning the route (lazy so helpers exist at call time)
#   permission: pundit-style string gate (nil = always visible)
#   position:   sort order in the nav
class ModuleRegistry
  Entry = Struct.new(:key, :name, :path, :permission, :position, keyword_init: true)

  ENTRIES = [
    Entry.new(key: "dashboard", name: "Dashboard", path: -> { root_path }, permission: nil, position: 10),
    Entry.new(key: "sales", name: "Sales", path: -> { sales_path }, permission: "sales.read", position: 20),
    Entry.new(key: "customers", name: "Customers", path: -> { customers_path }, permission: "customers.read", position: 30),
    Entry.new(key: "inventory", name: "Inventory", path: -> { inventory_index_path }, permission: "inventory.read", position: 40),
    Entry.new(key: "reconcile", name: "Reconcile", path: -> { reconcile_index_path }, permission: "reconcile.read", position: 50),
    Entry.new(key: "ledger", name: "Ledger", path: -> { ledger_index_path }, permission: "ledger.read", position: 60),
    Entry.new(key: "projects", name: "Projects", path: -> { projects_projects_path }, permission: "projects.read", position: 70),
    Entry.new(key: "goals", name: "Goals", path: -> { goals_goals_path }, permission: "projects.read", position: 75),
    Entry.new(key: "kpis", name: "KPIs", path: -> { goals_kpis_path }, permission: "projects.read", position: 78),
    Entry.new(key: "alerts", name: "Alerts", path: -> { alerts_path }, permission: "alerts.read", position: 80),
    Entry.new(key: "sync", name: "Sync", path: -> { syncs_path }, permission: "sync.read", position: 90),
    Entry.new(key: "settings", name: "Settings", path: -> { settings_path }, permission: "settings.read", position: 100),
  ].freeze

  class << self
    def all
      ENTRIES
    end

    # Nav entries visible to a user, sorted by position.
    def nav_for(user)
      all.select { |e| e.permission.nil? || user.can?(e.permission) }.sort_by(&:position)
    end

    def find(key)
      all.find { |e| e.key == key.to_s }
    end

    # Top-level ERP areas that group modules in the header. "modules" lists the
    # entry keys that belong to the area, in display order.
    AREAS = [
      { key: "overview", name: "Overview", modules: ["dashboard"] },
      { key: "commerce", name: "Commerce", modules: ["sales", "customers", "inventory"] },
      { key: "operations", name: "Operations", modules: ["reconcile", "ledger", "projects", "goals", "kpis"] },
      { key: "system", name: "System", modules: ["alerts", "sync", "settings"] },
    ].freeze

    def area_key_for(module_key)
      AREAS.find { |area| area[:modules].include?(module_key.to_s) }&.dig(:key)
    end

    # Areas with their modules filtered by the user's permissions.
    def areas_for(user)
      visible = nav_for(user)
      AREAS.filter_map do |area|
        modules = visible.select { |entry| area[:modules].include?(entry.key) }
        next if modules.empty?

        { key: area[:key], name: area[:name], modules: modules }
      end
    end
  end
end
