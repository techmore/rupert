# frozen_string_literal: true

module ApplicationHelper
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
        pill: "pill-clay"
      }
    end

    presenter.recent_alerts.each do |alert|
      break if items.length >= 5
      items << {
        label: alert.sku.presence || alert.id.first(10),
        note: "Low stock · #{alert.quantity} left / threshold #{alert.threshold}",
        value: alert.quantity <= 0 ? "out" : "low",
        pill: alert.quantity <= 0 ? "pill-rose" : "pill-clay"
      }
    end

    items
  end
end
