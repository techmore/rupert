# frozen_string_literal: true

# Shared words and pills for shift trades (docs/time-and-pay/DESIGN.md).
module ShiftTradesHelper
  TRADE_PILLS = {
    'open' => %w[pill-clay Open],
    'accepted' => %w[pill-clay Waiting],
    'approved' => %w[pill-fern Approved],
    'denied' => %w[pill-rose Denied],
    'cancelled' => %w[pill-taupe Cancelled],
    'expired' => %w[pill-taupe Expired]
  }.freeze

  def trade_status_pill(trade)
    css, word = TRADE_PILLS.fetch(trade.status, ['pill-taupe', trade.status.humanize])
    tag.span(t("time.schedule.trades.status.#{trade.status}", default: word), class: css)
  end

  def trade_shift_label(shift)
    return '' if shift.nil?

    "#{shift.starts_at.strftime('%a %b %-d')} · #{shift.time_label}#{" · #{shift.location.name}" if shift.location}"
  end

  # "Give away" / "Swap" / "Pick up" in the worker's language.
  def trade_kind_label(trade)
    t("time.schedule.trades.kinds.#{trade.kind}", default: trade.kind_label)
  end
end
