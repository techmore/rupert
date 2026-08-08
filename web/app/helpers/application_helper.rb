# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend

  # --- Module-area navigation helpers (see ModuleRegistry) ---

  def nav_areas
    @nav_areas ||= ModuleRegistry.areas_for(Current.user)
  end

  # Safely evaluate a module's lazy path; "#" keeps the nav alive if a route
  # helper is missing (e.g. mid-development).
  def safe_module_path(entry)
    instance_exec(&entry.path)
  rescue StandardError
    "#"
  end

  def module_match_strength(path)
    return 0 if path.blank? || path == "#"

    return request.path == "/" ? 100 : 0 if path == "/"

    return path.length if request.path == path
    return path.length if request.path.start_with?("#{path}/")

    0
  end

  def active_module_entry
    @active_module_entry ||= ModuleRegistry.nav_for(Current.user)
      .max_by { |entry| module_match_strength(safe_module_path(entry)) }
  end

  def active_area_key
    @active_area_key ||= ModuleRegistry.area_key_for(active_module_entry&.key) ||
      nav_areas.first&.dig(:key)
  end

  def active_area_modules
    nav_areas.find { |area| area[:key] == active_area_key }&.dig(:modules) || []
  end

  def vs_yesterday(today_cents, yesterday_cents)
    return "vs yesterday" if today_cents.nil? || yesterday_cents.nil? || yesterday_cents.zero?

    delta = today_cents - yesterday_cents
    pct = (delta.to_f / yesterday_cents * 100).round
    "#{pct.positive? ? "+" : ""}#{pct}% vs yesterday"
  end

  def attention_items(presenter)
    items = []
    drift = presenter.reconcile_summary[:drift_count]
    actionable = presenter.reconcile_summary[:actionable]

    if drift.positive?
      items << {
        label: "#{drift} SKUs out of sync",
        note: "#{actionable} need an adjustment — Shopify vs Square differ",
        value: actionable.to_s,
        pill: "pill-clay",
      }
    end

    presenter.recent_alerts.each do |alert|
      break if items.length >= 5

      items << {
        label: alert.sku.presence || alert.id.first(10),
        note: "Low stock · #{alert.quantity} left / threshold #{alert.threshold}",
        value: alert.quantity <= 0 ? "out" : "low",
        pill: alert.quantity <= 0 ? "pill-rose" : "pill-clay",
      }
    end

    items
  end
end
