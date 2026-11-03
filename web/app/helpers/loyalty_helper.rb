# frozen_string_literal: true

module LoyaltyHelper
  PROMOTION_PILLS = { 'ACTIVE' => 'pill-fern', 'SCHEDULED' => 'pill-clay', 'ENDED' => 'pill-taupe', 'CANCELED' => 'pill-taupe' }.freeze

  # "Oct 21, 2026" (docs/ui-standards.md §7); with_time adds " · 3:40 PM".
  def loyalty_date(value, with_time: false)
    return '—' unless value

    value = value.in_time_zone if with_time
    text = value.strftime('%b %-d, %Y')
    with_time ? "#{text} · #{value.strftime('%-l:%M %p')}" : text
  end

  # "1,250 points" in the program's own wording ("stars", "leaves" …).
  def loyalty_points(count, program = nil)
    word = program ? program.point_word(count) : (count.to_i.abs == 1 ? 'point' : 'points')
    "#{number_with_delimiter(count.to_i)} #{word}"
  end

  # "+12" / "−40" with a real minus sign; blank for events that move no points.
  def loyalty_change(points)
    return '—' if points.to_i.zero?

    points.positive? ? "+#{number_with_delimiter(points)}" : "−#{number_with_delimiter(points.abs)}"
  end

  # "1 point per $1.00 spent", "10 points per visit (minimum $5.00)".
  def loyalty_accrual_rule(rule, program)
    points = rule['points'].to_i
    amount = rule['amount_cents'] && operations_money(rule['amount_cents'], currency: rule['currency'].presence || 'USD')
    earned = loyalty_points(points, program)
    case rule['accrual_type']
    when 'SPEND' then amount ? "#{earned} per #{amount} spent" : "#{earned} per amount spent"
    when 'VISIT' then amount ? "#{earned} per visit (minimum #{amount})" : "#{earned} per visit"
    when 'ITEM_VARIATION' then "#{earned} per qualifying item"
    when 'CATEGORY' then "#{earned} per item in a qualifying category"
    else earned
    end
  end

  def loyalty_promotion_pill(promotion)
    tag.span(promotion.status.to_s.humanize.presence || 'Unknown', class: PROMOTION_PILLS.fetch(promotion.status, 'pill-taupe'))
  end

  # Sync status line for the loyalty source: when it last read, and any failure.
  def loyalty_read_status(state)
    at = state['last_success_at'].presence && (Time.iso8601(state['last_success_at']) rescue nil)
    at ? "Last read #{loyalty_date(at, with_time: true)}" : 'Not read yet'
  end

  # Everything the customer page's loyalty section shows, in a few queries.
  def customer_loyalty(customer)
    accounts = SquareLoyaltyAccount.for_customer(customer).order(source_present: :desc, balance: :desc, id: :asc).to_a
    program = SquareLoyaltyProgram.current
    return if accounts.empty? && (customer.source != 'square' || program.nil?)

    tiers = program ? program.reward_tiers.current.order(:points, :id).to_a : []
    events = SquareLoyaltyEvent.where(loyalty_account_external_id: accounts.map(&:external_id)).order(occurred_at: :desc, id: :desc).limit(10).to_a
    order_ids = events.filter_map(&:order_id).uniq
    orders = order_ids.any? ? Core::Order.where(source: 'square', source_order_id: order_ids).index_by(&:source_order_id) : {}
    { accounts: accounts, program: program, tiers: tiers, events: events, orders: orders,
      event_count: SquareLoyaltyEvent.where(loyalty_account_external_id: accounts.map(&:external_id)).count }
  end
end
