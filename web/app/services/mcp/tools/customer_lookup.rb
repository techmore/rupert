# frozen_string_literal: true

module Mcp
  module Tools
    # "Pull up Mrs. Patel": one customer's profile, spend, orders, follow-ups
    # and notes, without email, phone or address.
    class CustomerLookup < Tool
      # Shared by the customer tools: what counts as a sale, privacy redaction
      # and per-currency money rows.
      module Shared
        COUNTED = %w[paid fulfilled].freeze
        NOT_STORED = 'Rupert does not record subscriptions, referrals or loyalty points for shop customers. ' \
                     '(Its subscription and referral records are the shop\'s own Rupert billing, not customer data.)'
        EMAIL = /[^\s@<>()]+@[^\s@<>()]+\.[a-z]{2,}/i
        PHONE = /(?<!\w)\+?\d[\d\s().-]{6,}\d(?!\w)/

        private

        def paths = Rails.application.routes.url_helpers

        # Hide email addresses and phone numbers typed into free text.
        def redact(text, limit)
          text.to_s.gsub(EMAIL, '[email hidden]').gsub(PHONE, '[phone hidden]').squish.truncate(limit)
        end

        def window_for(from, to)
          from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day
        end

        def time_value(value)
          return value if value.nil? || value.respond_to?(:iso8601)

          Time.zone.parse(value.to_s)
        end

        def money_row(currency, cents_value, extra = {})
          { currency: currency, cents: cents_value.to_i, dollars: money(cents_value.to_i) }.merge(extra)
        end

        def money_text(rows)
          rows.map { |row| "#{row[:dollars]} #{row[:currency]}" }.join(' + ')
        end

        def staff_name(user) = user && (user.name.presence || "User #{user.id}")

        def counted_orders = Core::Order.where(status: COUNTED)

        # { customer_id => [{currency:, cents:, dollars:, orders:}] } for the given ids.
        def spend_by_customer(ids, scope = counted_orders)
          scope.where(customer_id: ids).group(:customer_id, :currency).pluck(:customer_id, :currency, Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(gross_cents), 0)'))
            .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(id, currency, count, total), out|
              out[id] << money_row(currency, total, orders: count)
            end
        end
      end

      include Shared

      HONORIFICS = %w[mr mrs ms miss mx dr].freeze

      tool 'customer_lookup',
        title: 'Customer profile and history',
        description: 'Finds one shop customer by name (a first name, last name or part of one, e.g. "Patel" or "Leo"), by ' \
                     'customer id, or by an order number ("who is the customer on order 10482"), and returns their profile: ' \
                     'CRM status (lead, customer, vip, inactive), tags, owner, customer-since date and notes; lifetime ' \
                     'value (paid order count and spend per currency, average and biggest order, first and last order ' \
                     'date, refunds), spend in an optional date range, what they usually buy, recent orders with what ' \
                     'was in the last one, open follow-ups and recent calls, emails, meetings and notes. Lists other ' \
                     'customers with similar names. Never returns email, phone or address and cannot search by them. ' \
                     'Rupert stores no customer subscriptions, referrals or loyalty points. Read-only.',
        scope: 'customers:read'

      input_schema(
        type: 'object',
        properties: {
          query: { type: 'string', maxLength: 100, description: 'Customer name or part of it ("Mrs. Patel", "Leo"), or a customer id.' },
          customer_id: { type: 'integer', minimum: 1, description: 'Exact customer id (from another result).' },
          order_number: { type: 'string', maxLength: 60, description: 'Find the customer on this order number, e.g. 10482 or #10482.' },
          from: DATE_PROPERTY.merge(description: 'Optional: also total spend from this day (inclusive), YYYY-MM-DD.'),
          to: DATE_PROPERTY.merge(description: 'Optional: last day of that spend range (inclusive). Default today.'),
          recent_orders: { type: 'integer', minimum: 0, maximum: 25, description: 'How many recent orders to list. Default 5.' },
          recent_interactions: { type: 'integer', minimum: 0, maximum: 25, description: 'How many recent interactions to list. Default 5.' }
        },
        additionalProperties: false
      )

      def call(args)
        customer, others, total_matches = find_customer(args)
        profile = profile(customer)
        lifetime = lifetime(customer)
        data = { customer: profile, lifetime: lifetime, period: period(customer, args), usually_buys: usually_buys(customer),
                 recent_orders: recent_orders(customer, (args['recent_orders'] || 5).to_i), follow_ups: follow_ups(customer),
                 interactions: interactions(customer, (args['recent_interactions'] || 5).to_i),
                 subscriptions: { stored: false, note: NOT_STORED }, referrals: { stored: false, note: NOT_STORED },
                 other_matches: others, total_matches: total_matches,
                 note: 'Spend counts paid and fulfilled orders linked to this customer profile. Fully refunded and unpaid orders ' \
                       'are excluded; partial refunds are listed under refunds. Another profile (other source) may be the same person.' }
        result(summary(data), data)
      end

      private

      def find_customer(args)
        if args['customer_id'].present?
          return [Core::Customer.find_by(id: args['customer_id'].to_i) || not_found("No customer has id #{args['customer_id']}."), [], 1]
        end
        return from_order(args['order_number']) if args['order_number'].present?

        query = args['query'].to_s.strip
        raise ToolError.new('Give a customer name, a customer id or an order number.', kind: 'invalid_arguments') if query.blank?
        return from_order(query) if query.match?(/\A#\d+\z/)

        if query.match?(/\A\d+\z/)
          customer = Core::Customer.find_by(id: query.to_i)
          return customer ? [customer, [], 1] : from_order(query)
        end

        by_name(query)
      end

      def from_order(number)
        value = number.to_s.strip.delete_prefix('#')
        order = Core::Order.where(order_number: [value, "##{value}"]).or(Core::Order.where(source_order_id: value)).order(occurred_at: :desc).first
        not_found("No order numbered #{value} is stored.") unless order
        not_found("Order #{order.display_number} has no customer linked (a walk-in or guest sale).") unless order.customer
        [order.customer, [], 1]
      end

      def by_name(query)
        words = query.downcase.gsub(/'s\b/, '').scan(/[[:alnum:]-]+/).reject { |word| HONORIFICS.include?(word) }
        words = query.downcase.scan(/[[:alnum:]-]+/) if words.empty?
        name_sql = "COALESCE(customers.preferred_name, '') || ' ' || COALESCE(customers.first_name, '') || ' ' || COALESCE(customers.last_name, '')"
        scope = words.reduce(Core::Customer.all) do |relation, word|
          relation.where("#{name_sql} LIKE ? COLLATE NOCASE", "%#{Core::Customer.sanitize_sql_like(word)}%")
        end
        total = scope.count
        not_found("No customer name matches \"#{query.truncate(60)}\". Try a last name or part of it.") if total.zero?

        candidates = scope.order(:id).limit(50).to_a
        stats = counted_orders.where(customer_id: candidates.map(&:id)).group(:customer_id).pluck(:customer_id, Arel.sql('COUNT(*)'), Arel.sql('MAX(occurred_at)'))
          .to_h { |id, count, last| [id, [count, time_value(last)]] }
        ranked = candidates.sort_by do |customer|
          count, last = stats[customer.id]
          [match_rank(customer, words), -count.to_i, -(last&.to_i || 0), customer.id]
        end
        others = ranked.drop(1).first(10).map do |customer|
          { id: customer.id, name: customer.name, crm_status: customer.crm_status, paid_orders: stats.dig(customer.id, 0).to_i }
        end
        [ranked.first, others, total]
      end

      def match_rank(customer, words)
        full = [customer.first_name, customer.last_name].compact.join(' ').downcase
        names = [customer.preferred_name, customer.first_name, customer.last_name].compact.map(&:downcase)
        return 0 if words.join(' ') == full || words.join(' ') == customer.preferred_name.to_s.downcase
        return 1 if words.all? { |word| names.any? { |name| name.split(/\s+/).include?(word) } }

        2
      end

      def not_found(message) = raise(ToolError.new(message, kind: 'not_found'))

      def profile(customer)
        { id: customer.id, name: customer.name, first_name: customer.first_name, last_name: customer.last_name,
          preferred_name: customer.preferred_name, crm_status: customer.crm_status, tags: customer.tag_list,
          owner: staff_name(customer.owner), source: customer.source, customer_since: iso(customer.created_at),
          last_synced_at: iso(customer.source_synced_at), notes: customer.notes.present? ? redact(customer.notes, 400) : nil,
          email_on_file: customer.email.present?, phone_on_file: customer.phone.present?,
          loyalty: nil, segment: customer.crm_status, path: paths.customer_path(customer) }
      end

      def lifetime(customer)
        counted = customer.orders.where(status: COUNTED)
        totals = counted.group(:currency).pluck(:currency, Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(gross_cents), 0)'), Arel.sql('MAX(gross_cents)'))
          .map do |currency, count, total, biggest|
            money_row(currency, total, orders: count, average_order_cents: (total.to_f / count).round, average_order_dollars: money((total.to_f / count).round),
              biggest_order_cents: biggest.to_i, biggest_order_dollars: money(biggest.to_i))
          end
        first, last = counted.pick(Arel.sql('MIN(occurred_at)'), Arel.sql('MAX(occurred_at)'))
        refunds = Core::Refund.joins(:order).where(orders: { customer_id: customer.id }).group('orders.currency')
          .pluck(Arel.sql('orders.currency'), Arel.sql('COUNT(*)'), Arel.sql('SUM(refunds.amount_cents)'))
          .map { |currency, count, total| money_row(currency, total, refunds: count) }
        { paid_orders: totals.sum { |row| row[:orders] }, spend_by_currency: totals, first_order_at: iso(time_value(first)),
          last_order_at: iso(time_value(last)), days_since_last_order: last ? (Date.current - time_value(last).to_date).to_i : nil,
          orders_by_status: customer.orders.group(:status).count, refunds_by_currency: refunds }
      end

      def period(customer, args)
        return if args['from'].blank? && args['to'].blank?

        from, to = date_range(args, default_from: Date.current.beginning_of_year, max_days: 3700)
        rows = customer.orders.where(status: COUNTED, occurred_at: window_for(from, to)).group(:currency)
          .pluck(:currency, Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(gross_cents), 0)'))
          .map { |currency, count, total| money_row(currency, total, orders: count) }
        { from: from.iso8601, to: to.iso8601, paid_orders: rows.sum { |row| row[:orders] }, spend_by_currency: rows }
      end

      def usually_buys(customer)
        Core::OrderLine.where(order_id: customer.orders.where(status: COUNTED).select(:id)).group(:name, :sku)
          .order(Arel.sql('SUM(quantity) DESC'), :name).limit(5)
          .pluck(:name, :sku, Arel.sql('SUM(quantity)'), Arel.sql('COUNT(DISTINCT order_id)'))
          .map { |name, sku, quantity, orders| { name: name, sku: sku, quantity: quantity.to_i, orders: orders } }
      end

      def recent_orders(customer, limit)
        return [] unless limit.positive?

        orders = customer.orders.order(occurred_at: :desc, id: :desc).limit(limit).to_a
        orders.map.with_index do |order, index|
          row = { id: order.id, number: order.display_number, occurred_at: iso(order.occurred_at), status: order.status,
                  fulfillment_status: order.fulfillment_status, source: order.source, channel: order.channel, currency: order.currency,
                  gross_cents: cents(order.gross_cents), gross_dollars: money(order.gross_cents), path: paths.order_path(order) }
          row[:items] = order.order_lines.order(:id).limit(10).map { |line| { name: line.name, sku: line.sku, quantity: line.quantity } } if index.zero?
          row
        end
      end

      def follow_ups(customer)
        open = customer.follow_ups.open
        rows = open.includes(:owner).order(:due_on, :id).limit(10).map do |follow_up|
          { id: follow_up.id, title: redact(follow_up.title, 160), due_on: follow_up.due_on.iso8601, overdue: follow_up.due_on < Date.current,
            owner: staff_name(follow_up.owner) }
        end
        last_done = customer.follow_ups.where.not(completed_at: nil).maximum(:completed_at)
        { open: open.count, overdue: open.where(due_on: ...Date.current).count, last_completed_at: iso(last_done), rows: rows }
      end

      def interactions(customer, limit)
        scope = customer.interactions
        rows = scope.includes(:author).order(created_at: :desc, id: :desc).limit(limit).map do |interaction|
          { kind: interaction.kind, at: iso(interaction.created_at), by: staff_name(interaction.author), summary: redact(interaction.body, 200) }
        end
        { total: scope.count, by_kind: scope.group(:kind).count, last_contact_at: iso(scope.maximum(:created_at)), rows: rows }
      end

      def summary(data)
        customer = data[:customer]
        lifetime = data[:lifetime]
        text = +"#{customer[:name]} (id #{customer[:id]}, #{customer[:crm_status]}"
        text << ", tags: #{customer[:tags].first(4).join(', ')}" if customer[:tags].any?
        text << '): '
        text << if lifetime[:paid_orders].zero?
          'no paid orders linked'
        else
          "#{lifetime[:paid_orders]} paid orders, #{money_text(lifetime[:spend_by_currency])} lifetime, last order #{lifetime[:last_order_at].to_s.first(10)}"
        end
        text << "; #{data[:period][:from]} to #{data[:period][:to]}: #{data[:period][:paid_orders]} orders #{money_text(data[:period][:spend_by_currency])}" if data[:period]
        text << "; #{data[:follow_ups][:open]} open follow-ups (#{data[:follow_ups][:overdue]} overdue)" if data[:follow_ups][:open].positive?
        text << "; last contact #{data[:interactions][:last_contact_at].to_s.first(10)}" if data[:interactions][:last_contact_at]
        text << '.'
        text << " Also matched: #{data[:other_matches].first(5).map { |row| row[:name] }.join(', ')}." if data[:other_matches].any?
        text.truncate(590)
      end
    end
  end
end
