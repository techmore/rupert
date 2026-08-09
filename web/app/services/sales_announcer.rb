# frozen_string_literal: true

# Static (non-AI) sales announcer. After a sync imports new orders, this
# service diffs the LedgerEntry rows newer than the last-announced watermark
# and posts a terse "item — amount" message to the Announcements channel.
#
# On first run with no watermark, it simply establishes a baseline at the
# newest existing order so historical sales are never re-announced in bulk.
class SalesAnnouncer
  WATERMARK_KEY = 'sales_announcer_watermark'
  REVENUE_STATUSES = %w[PAID COMPLETED].freeze

  class << self
    def announce!(channel: nil)
      new(channel: channel).announce!
    end
  end

  def initialize(channel: nil)
    @channel = channel.presence || announcements_channel
  end

  # Returns the number of new sales announced (0 if none, or if Buzz/watermark
  # isn't yet usable).
  def announce!
    return 0 unless BuzzAgent.configured?
    return 0 if baseline_not_established?

    entries = new_entries
    return 0 if entries.empty?

    BuzzAgent.notify(format_message(entries), channel: @channel)
    advance_watermark(entries)
    entries.length
  end

  private

  def announcements_channel
    EnvStore.fetch('BUZZ_ANNOUNCEMENTS_CHANNEL', '').presence || BuzzAgent.channel_id
  end

  def baseline_not_established?
    return false if watermark.present?

    # First run: set the watermark to the newest existing order (baseline) so
    # we only announce sales that arrive after this point.
    newest = LedgerEntry.order(occurredAt: :desc).first
    if newest
      update_watermark(newest.occurredAt)
    else
      # No orders at all yet — anchor to now so future orders count as new.
      update_watermark(Time.current)
    end
    true
  end

  def new_entries
    LedgerEntry
      .where(status: REVENUE_STATUSES)
      .where('"occurredAt" > ?', watermark)
      .order(:occurredAt)
      .limit(100)
  end

  def format_message(entries)
    lines = entries.map do |entry|
      amount = format('$%.2f', entry.grossCents.to_f / 100.0)
      items = entry.summary.presence || 'Sale'
      "#{entry.source} · #{items} — #{amount}"
    end
    "New sales:\n#{lines.join("\n")}"
  end

  def watermark
    @watermark ||= begin
      value = Setting.find_by(key: WATERMARK_KEY, tenant_id: Current.tenant_id)&.value
      value.present? ? Time.zone.parse(value) : nil
    rescue StandardError
      nil
    end
  end

  def update_watermark(time)
    setting = Setting.find_or_initialize_by(key: WATERMARK_KEY, tenant_id: Current.tenant_id)
    setting.value = time.utc.iso8601(6)
    setting.save!
    @watermark = time
  end

  def advance_watermark(entries)
    newest = entries.map(&:occurredAt).max
    update_watermark(newest) if newest && (watermark.nil? || newest > watermark)
  end
end
