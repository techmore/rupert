# frozen_string_literal: true

module Marketing
  # Counts a marketing event's discount-code redemptions from the orders Rupert has already stored (#415). Read-only
  # towards every outside system: it reads the local `orders` table (filled by the Shopify, Square and POS syncs) and
  # never calls Shopify or Square, and never changes an order. It writes only marketing_results rows.
  #
  # An order counts when one of its codes (matched case-insensitively) is the event's code, it happened inside the
  # window (the event's local start and end unless given), it is not cancelled or refunded, it is at the event's store
  # location when the event names one, and no other event has already counted it. Results are split by order source
  # and currency, so different currencies are never added together. Revenue is the order total before tax and tips.
  # Counting again replaces this event's stored-order rows for the code.
  class RedemptionCount
    class Refused < StandardError; end

    LIMIT = 10_000
    COUNTED_STATUSES = %w[placed paid fulfilled].freeze

    def self.call(...) = new(...).call

    def initialize(event, actor:, code: nil, from: nil, to: nil)
      @event = event
      @actor = actor
      @offer = Marketing::Offer.find_by(id: event.details['offer_id']) if event.details['offer_id'].present?
      @code = (code.presence || @offer&.code).to_s.strip.upcase
      @from = from || Marketing::WorkKinds.local_time(event, 'starts_at')
      @to = to || Marketing::WorkKinds.local_time(event, 'ends_at')
      @location = event.details['location_id'].to_s
    end

    def call
      raise Refused, 'Choose a discount code to count.' unless @code.match?(/\A[A-Z0-9_-]{2,80}\z/)
      raise Refused, 'Give the counting window a start before its end.' unless @from && @to && @to > @from
      raise Refused, 'Count at most 92 days at a time.' if @to - @from > 92.days

      rows = matching_orders.pluck(:id, :source, :currency, :gross_cents, :tax_cents, :tip_cents)
      raise Refused, "More than #{LIMIT} orders match; narrow the window." if rows.size > LIMIT

      claimed = Marketing::Result.claimed_order_ids(except_event_id: @event.id)
      rows.reject! { |row| claimed.include?(row[0]) }
      groups = rows.group_by { |_, source, currency| [source.to_s, (currency.presence || 'USD').upcase] }

      Marketing::Result.transaction do
        existing = Marketing::Result.where(work_item_id: @event.id, code: @code, location_id: @location, basis: 'stored_orders').lock.to_a
        kept = groups.map { |(source, currency), orders| save_group(existing, source, currency, orders) }
        (existing - kept).each(&:destroy!)
        ActivityLogger.log('marketing_event_results_counted', subject: @event, actor: @actor,
          details: "Code #{@code}: #{rows.size} orders from #{@from.to_fs(:short)} to #{@to.to_fs(:short)}")
        kept
      end
    end

    private

    def matching_orders
      scope = Core::Order.where(occurred_at: @from..@to, status: COUNTED_STATUSES)
        .where('EXISTS (SELECT 1 FROM json_each(orders.discount_codes) WHERE UPPER(TRIM(json_each.value)) = ?)', @code)
      @location.present? ? scope.where(location_id: @location) : scope
    end

    def save_group(existing, source, currency, orders)
      result = existing.find { |row| row.order_source == source && row.currency == currency } ||
               Marketing::Result.new(work_item_id: @event.id, code: @code, location_id: @location, order_source: source, currency: currency,
                 basis: 'stored_orders')
      result.update!(offer: @offer&.code == @code ? @offer : nil, window_starts_at: @from, window_ends_at: @to, redemptions: orders.size,
        revenue_cents: orders.sum { |row| [row[3].to_i - row[4].to_i - row[5].to_i, 0].max }, order_ids: orders.map(&:first).sort,
        recorded_by: @actor, summary: "#{orders.size} stored #{'order'.pluralize(orders.size)} used #{@code}.")
      result
    end
  end
end
