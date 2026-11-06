# frozen_string_literal: true

require 'csv'

module Tips
  # Figures for the manager Tips page and the pay export: one pay period's tip ledger by status,
  # person, store and day, plus the settlement sources it was matched to.
  #
  #   report = Tips::ReconciliationReport.for(starts_on, ends_on)
  #   report.totals[:settled_cents]; report.by_employee; report.unassigned; report.settlements
  class ReconciliationReport
    Row = Struct.new(:employee, :card_cents, :cash_cents, :final_cents, :estimated_cents, :shares, :rows, keyword_init: true)

    attr_reader :starts_on, :ends_on

    def self.for(starts_on, ends_on)
      new(starts_on, ends_on)
    end

    def initialize(starts_on, ends_on)
      @starts_on = starts_on
      @ends_on = ends_on
    end

    # Rows that count toward this period: dated inside it, or carried into it from a locked one.
    def allocations
      @allocations ||= TipAllocation.where(pay_period_start: starts_on).or(TipAllocation.where(business_date: starts_on..ends_on, pay_period_start: nil))
        .includes(:employee).order(:occurred_at, :id).to_a
    end

    # Sums always take every row: a reversed original and its mirrored negative row add up to zero.
    def totals
      @totals ||= begin
        live = allocations
        {
          terminal_cents: allocations.select { |a| a.card? && a.amount_cents.positive? && %w[dejavoo_feed_event order].include?(a.source_kind) }.sum(&:amount_cents),
          settled_cents: live.select { |a| a.card? && a.status != 'estimated' }.sum(&:amount_cents),
          estimated_cents: live.select { |a| a.card? && a.status == 'estimated' }.sum(&:amount_cents),
          cash_cents: live.select { |a| a.tip_method == 'cash' }.sum(&:amount_cents),
          unassigned_cents: live.select(&:unassigned?).sum(&:amount_cents),
          reversed_cents: allocations.select { |a| a.reverses_id.present? }.sum(&:amount_cents),
          adjustment_cents: live.select { |a| a.tip_method == 'adjustment' }.sum(&:amount_cents),
          total_cents: live.sum(&:amount_cents)
        }
      end
    end

    def by_employee
      @by_employee ||= allocations.reject { |a| a.employee.nil? }.group_by(&:employee).map do |employee, rows|
        Row.new(employee: employee, card_cents: rows.select(&:card?).sum(&:amount_cents), cash_cents: rows.select { |r| r.tip_method == 'cash' }.sum(&:amount_cents),
          final_cents: rows.reject { |r| r.status == 'estimated' }.sum(&:amount_cents), estimated_cents: rows.select { |r| r.status == 'estimated' }.sum(&:amount_cents),
          shares: rows.count { |r| r.tip_method == 'pool' && r.amount_cents.positive? }, rows: rows)
      end.sort_by { |row| row.employee.name.downcase }
    end

    def unassigned
      allocations.select { |a| a.unassigned? && a.status != 'reversed' && a.amount_cents.positive? && a.reverses_id.nil? }
    end

    def by_day
      allocations.group_by(&:business_date).sort.map do |date, rows|
        { date: date, card_cents: rows.select(&:card?).sum(&:amount_cents), cash_cents: rows.select { |r| r.tip_method == 'cash' }.sum(&:amount_cents),
          unassigned_cents: rows.select(&:unassigned?).sum(&:amount_cents) }
      end
    end

    def by_store
      allocations.group_by(&:location_id).map do |location_id, rows|
        { location: location_id && Location.find_by(id: location_id), card_cents: rows.select(&:card?).sum(&:amount_cents),
          cash_cents: rows.select { |r| r.tip_method == 'cash' }.sum(&:amount_cents), unassigned_cents: rows.select(&:unassigned?).sum(&:amount_cents) }
      end
    end

    # Settlement sources this period's rows were matched to, and the settled rows that still have none.
    def settlements
      live = allocations
      grouped = live.select { |a| a.settlement_ref.present? }.group_by(&:settlement_ref).map do |ref, rows|
        { ref: ref, label: settlement_label(ref), settled_at: rows.filter_map(&:settled_at).max, count: rows.size, tip_cents: rows.sum(&:amount_cents), matched: true }
      end
      unmatched = live.select { |a| a.card? && a.status == 'estimated' }
      grouped << { ref: nil, label: 'Not yet settled', settled_at: nil, count: unmatched.size, tip_cents: unmatched.sum(&:amount_cents), matched: false } if unmatched.any?
      grouped.sort_by { |g| [g[:matched] ? 0 : 1, g[:settled_at] || Time.zone.at(0)] }
    end

    def settlement_label(ref)
      case ref
      when /\Adejavoo-batch:(.+)/ then "Dejavoo batch #{Regexp.last_match(1)}"
      when /\Aanet:(.+)/ then "Authorize.net #{Regexp.last_match(1)}"
      else ref
      end
    end

    def to_csv
      CSV.generate do |csv|
        csv << ['Employee', 'Date', 'Source', 'Method', 'Status', 'Evidence', 'Share of', 'Amount', 'Settlement', 'Note']
        allocations.each do |a|
          csv << [a.employee&.name || 'Unassigned', a.business_date, a.source_kind.humanize, a.tip_method, a.status, a.evidence,
                  a.share_count.to_i.positive? ? a.share_count : '', format('%.2f', a.amount_cents / 100.0), a.settlement_ref, a.note.to_s.sub(/\A[=+\-@]/, "'\\0")]
        end
      end
    end
  end
end
