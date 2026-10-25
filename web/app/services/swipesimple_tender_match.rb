# frozen_string_literal: true

# Pairs each card tender Rupert's own POS recorded on one business day with the
# SwipeSimple transaction it corresponds to, by exact amount and a time window.
#
# Read-only: it reads completed Rupert POS card payments and stored SwipeSimple
# transaction rows (latest observation per transaction) and writes nothing.
#
# A pair is made only when it is the only possibility: one Rupert tender and
# one SwipeSimple sale of the same amount whose times are within WINDOW of each
# other, with nothing else of that amount close enough to either. When several
# tenders or sales of one amount overlap in time, the whole group is flagged as
# ambiguous and no pair is guessed.
class SwipesimpleTenderMatch
  # The cashier keys the amount on the terminal and records card in Rupert,
  # in either order, so the two clocks can differ by a few minutes.
  WINDOW = 10.minutes
  RUPERT_SOURCES = %w[rupert_pos].freeze

  Tender = Struct.new(:id, :order_number, :amount_cents, :at, keyword_init: true)
  Pair = Struct.new(:tender, :row, :seconds_apart, keyword_init: true)
  Ambiguous = Struct.new(:amount_cents, :tenders, :rows, keyword_init: true)

  attr_reader :window

  # window: the business day (Time range, America/New_York midnight to midnight).
  def initialize(window)
    @window = window
  end

  # Matching looks WINDOW past each edge of the day, so a sale rung at
  # 11:58 PM that the terminal stamped 12:03 AM still pairs; the pair is then
  # shown on both days and neither side is listed as unmatched.
  def search_window
    (window.begin - WINDOW)...(window.end + WINDOW)
  end

  def tenders
    @tenders ||= Core::Payment.completed.where(method: 'card', paid_at: search_window)
      .joins(:order).where(orders: { source: RUPERT_SOURCES }).includes(:order).order(:paid_at, :id)
      .map do |payment|
        Tender.new(id: payment.id, order_number: payment.order&.display_number || payment.order&.order_number,
          amount_cents: payment.amount_cents, at: payment.paid_at)
      end
  end

  # Approved card sales. Refunds, cash, unknown-tender and excluded attempts
  # are not card tenders and are left out.
  def swipesimple_rows
    @swipesimple_rows ||= SwipesimpleReportRow.latest.where(swipesimple_exports: { kind: 'transactions', currency: 'USD' })
      .where(occurred_at: search_window, status: 'Approved', transaction_type: 'Sale', tender: 'card')
      .includes(:swipesimple_export).order(:occurred_at, :id).to_a
  end

  def pairs
    result[:pairs].select { |pair| in_day?(pair.tender.at) || in_day?(pair.row.occurred_at) }
  end

  def ambiguous
    result[:ambiguous].select { |group| (group.tenders.map(&:at) + group.rows.map(&:occurred_at)).any? { |at| in_day?(at) } }
  end

  def unmatched_tenders
    result[:tenders].select { |tender| in_day?(tender.at) }
  end

  def unmatched_rows
    result[:rows].select { |row| in_day?(row.occurred_at) }
  end

  def day_tenders
    tenders.select { |tender| in_day?(tender.at) }
  end

  def day_rows
    swipesimple_rows.select { |row| in_day?(row.occurred_at) }
  end

  def no_tenders?
    day_tenders.empty?
  end

  def all_matched?
    ambiguous.empty? && unmatched_tenders.empty? && unmatched_rows.empty?
  end

  private

  def in_day?(time)
    window.cover?(time)
  end

  def close?(tender, row)
    (tender.at - row.occurred_at).abs <= WINDOW
  end

  def result
    @result ||= begin
      out = { pairs: [], ambiguous: [], tenders: [], rows: [] }
      by_amount = swipesimple_rows.group_by(&:amount_cents)
      tenders.group_by(&:amount_cents).each do |amount, list|
        components(list, by_amount.delete(amount) || []).each { |group| classify(amount, *group, out) }
      end
      out[:rows].concat(by_amount.values.flatten)
      out[:rows].sort_by! { |row| [row.occurred_at, row.id] }
      out
    end
  end

  # Connected groups of tenders and rows of one amount, linked when close in
  # time. Each group is either a lone item, one clean pair or ambiguous.
  def components(tender_list, row_list)
    seen_t = {}
    seen_r = {}
    tender_list.each_with_object([]) do |start, groups|
      next if seen_t[start.id]

      group_t = []
      group_r = []
      queue = [[:t, start]]
      seen_t[start.id] = true
      until queue.empty?
        kind, item = queue.shift
        if kind == :t
          group_t << item
          row_list.each do |row|
            next if seen_r[row.id] || !close?(item, row)

            seen_r[row.id] = true
            queue << [:r, row]
          end
        else
          group_r << item
          tender_list.each do |tender|
            next if seen_t[tender.id] || !close?(tender, item)

            seen_t[tender.id] = true
            queue << [:t, tender]
          end
        end
      end
      groups << [group_t, group_r]
    end.tap do |groups|
      row_list.reject { |row| seen_r[row.id] }.each { |row| groups << [[], [row]] }
    end
  end

  def classify(amount, group_t, group_r, out)
    if group_t.size == 1 && group_r.size == 1
      out[:pairs] << Pair.new(tender: group_t.first, row: group_r.first, seconds_apart: (group_t.first.at - group_r.first.occurred_at).abs.round)
    elsif group_r.empty?
      out[:tenders].concat(group_t)
    elsif group_t.empty?
      out[:rows].concat(group_r)
    else
      out[:ambiguous] << Ambiguous.new(amount_cents: amount, tenders: group_t.sort_by(&:at), rows: group_r.sort_by(&:occurred_at))
    end
  end
end
