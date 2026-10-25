# frozen_string_literal: true

module Mcp
  module Tools
    # Customer lists: best, new, repeat and lapsed customers, segments, due
    # follow-ups and logged interactions. Aggregates run in SQL.
    class CustomerInsights < Tool
      include CustomerLookup::Shared

      VIEWS = %w[top new repeat lapsed segments follow_ups interactions subscriptions].freeze
      FOLLOW_UP_STATUSES = %w[due overdue open completed].freeze

      tool 'customer_insights',
        title: 'Customer lists and insights',
        description: 'Lists of customers, with counts. view=top: best customers by spend (or order count) in a date range, ' \
                     'with each one\'s share of sales. view=new: first-time buyers (first ever paid order in the range), plus ' \
                     'new vs returning counts. view=repeat: customers with 2+ orders in the range and the repeat rate. ' \
                     'view=lapsed: customers who bought before but not in the last N days (default 90), most valuable first ' \
                     '(win-back / at-risk list; max_orders=1 for one-time buyers). view=segments: customer counts by CRM ' \
                     'status (lead, customer, vip, inactive), source and tag, and the customers in a status or tag. ' \
                     'view=follow_ups: customer follow-ups due, overdue, open or completed, by owner. view=interactions: ' \
                     'calls, emails, meetings and notes logged in the range. view=subscriptions: Rupert stores no customer ' \
                     'subscriptions or referrals, so this only explains that. Default range is the last 90 days. Spend is ' \
                     'paid and fulfilled orders linked to a customer profile; no email, phone or address. Paginated. Read-only.',
        scope: 'customers:read'

      input_schema(
        type: 'object',
        properties: {
          view: { type: 'string', enum: VIEWS, description: 'Which list. Default top.' },
          from: DATE_PROPERTY.merge(description: 'First day (inclusive), YYYY-MM-DD. Default 89 days before to.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive), YYYY-MM-DD. Default today.'),
          days: { type: 'integer', minimum: 1, maximum: 3650, description: 'lapsed: no order in this many days. Default 90.' },
          sort: { type: 'string', enum: %w[spend orders], description: 'top: rank by spend (default) or by order count.' },
          min_orders: { type: 'integer', minimum: 1, maximum: 1000, description: 'top/repeat/lapsed: at least this many orders (repeat default 2).' },
          max_orders: { type: 'integer', minimum: 1, maximum: 1000, description: 'top/repeat/lapsed: at most this many orders (lapsed max_orders=1 = bought once, never came back).' },
          channel: { type: 'string', enum: Core::Order::CHANNELS, description: 'top/new/repeat: only online, pos (in store) or manual orders.' },
          currency: { type: 'string', maxLength: 3, description: 'top: only this currency, e.g. USD.' },
          crm_status: { type: 'string', enum: Core::Customer::CRM_STATUSES, description: 'Only customers with this CRM status (e.g. vip).' },
          tag: { type: 'string', maxLength: 100, description: 'segments: only customers with this tag.' },
          added_in_range: { type: 'boolean', description: 'segments: only profiles created in the date range.' },
          status: { type: 'string', enum: FOLLOW_UP_STATUSES, description: 'follow_ups: due (today or earlier, default), overdue, open (all), completed (in the range).' },
          owner: { type: 'string', maxLength: 100, description: 'follow_ups/interactions: staff name, "me" or "unassigned".' },
          kind: { type: 'string', enum: CustomerInteraction::KINDS, description: 'interactions: only this kind.' },
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        view = args['view'] || 'top'
        to = date_arg(args, 'to', Date.current)
        @from, @to = date_range(args, default_from: to - 89, default_to: to, max_days: 3700)
        @window = window_for(@from, @to)
        run_view(view, args)
      end

      private

      def run_view(view, args)
        case view
        when 'top' then top(args)
        when 'new' then new_customers(args)
        when 'repeat' then repeat(args)
        when 'lapsed' then lapsed(args)
        when 'segments' then segments(args)
        when 'follow_ups' then follow_ups(args)
        when 'interactions' then interactions(args)
        when 'subscriptions' then subscriptions
        else raise ToolError.new("view must be one of #{VIEWS.join(', ')}.", kind: 'invalid_arguments')
        end
      end

      def range = { from: @from.iso8601, to: @to.iso8601 }

      def sales(args)
        scope = counted_orders.where(occurred_at: @window)
        scope = scope.where(channel: args['channel']) if args['channel'].present?
        scope
      end

      def linked(scope, args)
        scope = scope.where.not(customer_id: nil)
        scope = scope.where(customer_id: Core::Customer.where(crm_status: args['crm_status']).select(:id)) if args['crm_status'].present?
        scope
      end

      def order_bounds(grouped, args)
        grouped = grouped.having('COUNT(*) >= ?', args['min_orders'].to_i) if args['min_orders'].present?
        grouped = grouped.having('COUNT(*) <= ?', args['max_orders'].to_i) if args['max_orders'].present?
        grouped
      end

      # Number of groups in a grouped relation, counted in SQL.
      def group_count(grouped) = Core::Order.unscoped.from(grouped.select(:customer_id), :grouped_customers).count

      def customers_for(rows) = Core::Customer.where(id: rows.pluck(:customer_id)).index_by(&:id)

      # Pages a grouped order relation with pluck (no partial Order objects).
      # columns: { key => SQL expression }. Returns [hashes, meta].
      def grouped_page(grouped, columns, order, args)
        page, per_page = page_args(args)
        values = grouped.order(Arel.sql(order)).offset((page - 1) * per_page).limit(per_page + 1)
          .pluck(*columns.values.map { |sql| Arel.sql(sql) })
        rows = values.map { |row| columns.keys.zip(Array(row)).to_h }
        more = rows.size > per_page
        [rows.first(per_page), { page: page, per_page: per_page, has_more: more, next_page: more && page < MAX_PAGE ? page + 1 : nil }]
      end

      def customer_row(customer, id)
        { customer_id: id, name: customer&.name || 'Unknown profile', crm_status: customer&.crm_status,
          tags: customer ? customer.tag_list : [], path: paths.customer_path(id) }
      end

      def unlinked(scope) = scope.where(customer_id: nil).count

      def top(args)
        scope = sales(args)
        scope = scope.where(currency: args['currency'].upcase) if args['currency'].present?
        totals = scope.group(:currency).sum(:gross_cents)
        grouped = order_bounds(linked(scope, args).group(:customer_id, :currency), args)
        order = args['sort'] == 'orders' ? 'COUNT(*) DESC, SUM(gross_cents) DESC' : 'SUM(gross_cents) DESC, COUNT(*) DESC'
        page, meta = grouped_page(grouped, { customer_id: 'customer_id', currency: 'currency', order_count: 'COUNT(*)',
                                             spend: 'COALESCE(SUM(gross_cents), 0)', last_at: 'MAX(occurred_at)' }, "#{order}, customer_id", args)
        customers = customers_for(page)
        rows = page.map do |row|
          total = totals[row[:currency]].to_i
          customer_row(customers[row[:customer_id]], row[:customer_id]).merge(
            currency: row[:currency], orders: row[:order_count], spend_cents: row[:spend].to_i, spend_dollars: money(row[:spend].to_i),
            share_percent: total.positive? ? (row[:spend].to_f * 100 / total).round(1) : nil, last_order_at: iso(time_value(row[:last_at]))
          )
        end
        counts = { customers: group_count(grouped), orders_without_customer: unlinked(scope),
                   sales_by_currency: totals.map { |currency, value| money_row(currency, value) } }
        text = "#{range[:from]} to #{range[:to]}: #{counts[:customers]} customers bought. " +
               (rows.any? ? "Top: #{rows.first(8).map { |r| "#{r[:name]} #{r[:spend_dollars]} #{r[:currency]} (#{r[:orders]} orders)" }.join('; ')}." : 'No linked customer orders.') +
               orders_note(counts)
        result(text.truncate(590), range.merge(view: 'top', sort: args['sort'] || 'spend', counts: counts, rows: rows, meta: meta))
      end

      def orders_note(counts)
        counts[:orders_without_customer].positive? ? " #{counts[:orders_without_customer]} paid orders in the range have no customer linked." : ''
      end

      def new_customers(args)
        scope = sales(args)
        firsts = counted_orders.where.not(customer_id: nil).group(:customer_id)
          .having('MIN(occurred_at) >= ? AND MIN(occurred_at) < ?', @window.begin, @window.end)
        firsts = firsts.where(channel: args['channel']) if args['channel'].present?
        firsts = linked(firsts, args)
        page, meta = grouped_page(firsts, { customer_id: 'customer_id', first_at: 'MIN(occurred_at)', order_count: 'COUNT(*)' },
          'MIN(occurred_at) DESC, customer_id', args)
        customers = customers_for(page)
        spend = spend_by_customer(page.pluck(:customer_id))
        rows = page.map do |row|
          customer_row(customers[row[:customer_id]], row[:customer_id]).merge(first_order_at: iso(time_value(row[:first_at])),
            lifetime_orders: row[:order_count], lifetime_spend: spend[row[:customer_id]])
        end
        bought = group_count(linked(scope, args).group(:customer_id))
        new_count = group_count(firsts)
        counts = { new_customers: new_count, returning_customers: bought - new_count, customers_who_bought: bought,
                   profiles_created: Core::Customer.where(created_at: @window).count, orders_without_customer: unlinked(scope) }
        text = "#{range[:from]} to #{range[:to]}: #{new_count} new customers (first paid order), #{counts[:returning_customers]} returning. " \
               "#{counts[:profiles_created]} customer profiles were added." +
               (rows.any? ? " Newest: #{rows.first(6).map { |r| r[:name] }.join(', ')}." : '') + orders_note(counts)
        result(text.truncate(590), range.merge(view: 'new', counts: counts, rows: rows, meta: meta,
          note: 'New = first ever paid or fulfilled order falls in the range. profiles_created counts customer records added, which includes synced profiles with no orders.'))
      end

      def repeat(args)
        scope = sales(args)
        min = (args['min_orders'] || 2).to_i
        grouped = order_bounds(linked(scope, args).group(:customer_id), args.merge('min_orders' => min))
        page, meta = grouped_page(grouped, { customer_id: 'customer_id', order_count: 'COUNT(*)', last_at: 'MAX(occurred_at)' },
          'COUNT(*) DESC, MAX(occurred_at) DESC, customer_id', args)
        customers = customers_for(page)
        spend = spend_by_customer(page.pluck(:customer_id), scope)
        rows = page.map do |row|
          customer_row(customers[row[:customer_id]], row[:customer_id]).merge(orders: row[:order_count], last_order_at: iso(time_value(row[:last_at])),
            spend_in_range: spend[row[:customer_id]])
        end
        bought_groups = linked(scope, args).group(:customer_id)
        bought, all_orders = Core::Order.unscoped.from(bought_groups.select('customer_id, COUNT(*) AS n'), :g).pick(Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(g.n), 0)'))
        repeaters, repeat_orders = Core::Order.unscoped.from(grouped.select('customer_id, COUNT(*) AS n'), :g).pick(Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(g.n), 0)'))
        counts = { repeat_customers: repeaters.to_i, customers_who_bought: bought.to_i, min_orders: min,
                   repeat_rate_percent: bought.to_i.positive? ? (repeaters.to_f * 100 / bought).round(1) : nil,
                   orders_from_repeat_customers: repeat_orders.to_i, linked_orders: all_orders.to_i,
                   repeat_order_share_percent: all_orders.to_i.positive? ? (repeat_orders.to_f * 100 / all_orders).round(1) : nil,
                   orders_without_customer: unlinked(scope) }
        text = "#{range[:from]} to #{range[:to]}: #{counts[:repeat_customers]} of #{bought.to_i} customers ordered #{min}+ times " \
               "(#{counts[:repeat_rate_percent] || 0}% repeat rate, #{counts[:repeat_order_share_percent] || 0}% of linked orders)." +
               (rows.any? ? " Most orders: #{rows.first(6).map { |r| "#{r[:name]} (#{r[:orders]})" }.join(', ')}." : '') + orders_note(counts)
        result(text.truncate(590), range.merge(view: 'repeat', counts: counts, rows: rows, meta: meta))
      end

      def lapsed(args)
        days = (args['days'] || 90).to_i
        cutoff = (Date.current - days).in_time_zone.beginning_of_day
        grouped = order_bounds(linked(counted_orders, args).group(:customer_id).having('MAX(occurred_at) < ?', cutoff), args)
        page, meta = grouped_page(grouped, { customer_id: 'customer_id', order_count: 'COUNT(*)', last_at: 'MAX(occurred_at)', first_at: 'MIN(occurred_at)' },
          'SUM(gross_cents) DESC, COUNT(*) DESC, customer_id', args)
        customers = customers_for(page)
        spend = spend_by_customer(page.pluck(:customer_id))
        rows = page.map do |row|
          last = time_value(row[:last_at])
          customer_row(customers[row[:customer_id]], row[:customer_id]).merge(lifetime_orders: row[:order_count], lifetime_spend: spend[row[:customer_id]],
            first_order_at: iso(time_value(row[:first_at])), last_order_at: iso(last), days_since_last_order: last ? (Date.current - last.to_date).to_i : nil)
        end
        active = group_count(linked(counted_orders, args).group(:customer_id).having('MAX(occurred_at) >= ?', cutoff))
        counts = { lapsed_customers: group_count(grouped), active_customers: active, days: days, no_order_since: cutoff.to_date.iso8601 }
        text = "#{counts[:lapsed_customers]} customers have bought before but not since #{counts[:no_order_since]} (#{days} days); " \
               "#{active} bought since." +
               (rows.any? ? " Most valuable: #{rows.first(6).map { |r| "#{r[:name]} (last #{r[:last_order_at].to_s.first(10)}, #{money_text(r[:lifetime_spend])})" }.join('; ')}." : '')
        result(text.truncate(590), { view: 'lapsed', counts: counts, rows: rows, meta: meta,
                                     note: 'Ranked by lifetime spend. Only orders linked to a customer profile count.' })
      end

      def segments(args)
        scope = Core::Customer.all
        scope = scope.where(created_at: @window) if args['added_in_range']
        counts = { customers: scope.count, by_crm_status: scope.group(:crm_status).count, by_source: scope.group(:source).count,
                   top_tags: scope.where.not(tags: [nil, '']).pluck(:tags).flat_map { |tags| tags.split(',').map(&:strip) }.tally
                     .sort_by { |tag, count| [-count, tag] }.first(20).to_h }
        listed = scope
        listed = listed.where(crm_status: args['crm_status']) if args['crm_status'].present?
        if args['tag'].present?
          tag = Core::Customer.sanitize_sql_like(args['tag'].strip)
          listed = listed.where("(',' || REPLACE(tags, ', ', ',') || ',') LIKE ? COLLATE NOCASE", "%,#{tag},%")
        end
        listing = args['crm_status'].present? || args['tag'].present? || args['added_in_range']
        rows = []
        meta = nil
        if listing
          page, meta = paginate(listed.order(created_at: :desc, id: :desc), args)
          spend = spend_by_customer(page.map(&:id))
          rows = page.map { |customer| customer_row(customer, customer.id).merge(customer_since: iso(customer.created_at), lifetime_spend: spend[customer.id]) }
          counts[:matching] = listed.count
        end
        text = "#{counts[:customers]} customer profiles#{" added #{range[:from]} to #{range[:to]}" if args['added_in_range']}. By status: " +
               counts[:by_crm_status].map { |status, count| "#{status} #{count}" }.join(', ') + '.' +
               (counts[:top_tags].any? ? " Top tags: #{counts[:top_tags].first(6).map { |tag, count| "#{tag} #{count}" }.join(', ')}." : '') +
               (listing ? " #{counts[:matching]} match: #{rows.first(8).map { |r| r[:name] }.join(', ')}." : '')
        data = { view: 'segments', counts: counts, rows: rows, meta: meta,
                 note: 'Segments are the CRM status and tags set on each profile. Rupert has no loyalty tiers or points.' }
        data.merge!(range) if args['added_in_range']
        result(text.truncate(590), data)
      end

      def owner_filter(args)
        value = args['owner'].to_s.strip
        return if value.blank?
        return user.id if value.casecmp?('me')
        return :none if value.casecmp?('unassigned')

        ids = User.where(tenant_id: tenant.id).where('name LIKE ? COLLATE NOCASE', "%#{User.sanitize_sql_like(value)}%").pluck(:id)
        raise ToolError.new("No staff member's name matches \"#{value.truncate(40)}\".", kind: 'not_found') if ids.empty?

        ids
      end

      def follow_ups(args)
        status = args['status'] || 'due'
        base = CustomerFollowUp.all
        owner = owner_filter(args)
        base = owner == :none ? base.where(owner_id: nil) : base.where(owner_id: owner) if owner
        scope = case status
        when 'due' then base.due
        when 'overdue' then base.open.where(due_on: ...Date.current)
        when 'open' then base.open
        else base.where(completed_at: @window)
        end
        page, meta = paginate(scope.includes(:customer, :owner).order(status == 'completed' ? { completed_at: :desc, id: :desc } : { due_on: :asc, id: :asc }), args)
        rows = page.map do |follow_up|
          { id: follow_up.id, title: redact(follow_up.title, 160), customer_id: follow_up.customer_id, customer: follow_up.customer&.name,
            due_on: follow_up.due_on.iso8601, days_overdue: follow_up.completed_at ? nil : [(Date.current - follow_up.due_on).to_i, 0].max,
            owner: staff_name(follow_up.owner) || 'Unassigned', completed_at: iso(follow_up.completed_at), path: paths.customer_path(follow_up.customer_id) }
        end
        owners = User.where(tenant_id: tenant.id, id: scope.where.not(owner_id: nil).distinct.pluck(:owner_id)).index_by(&:id)
        by_owner = scope.group(:owner_id).count.to_h { |id, count| [id ? staff_name(owners[id]) : 'Unassigned', count] }
        open = base.open
        counts = { matching: scope.count, open: open.count, due: open.where(due_on: ..Date.current).count, due_today: open.where(due_on: Date.current).count,
                   overdue: open.where(due_on: ...Date.current).count, completed_in_range: base.where(completed_at: @window).count, by_owner: by_owner }
        text = "#{counts[:due]} customer follow-ups due (#{counts[:overdue]} overdue, #{counts[:due_today]} today), #{counts[:open]} open in all; " \
               "#{counts[:completed_in_range]} completed #{range[:from]} to #{range[:to]}." +
               (rows.any? ? " #{status.capitalize}: #{rows.first(6).map { |r| "#{r[:customer]}: #{r[:title].truncate(40)} (#{r[:due_on]}, #{r[:owner]})" }.join('; ')}." : '')
        result(text.truncate(590), range.merge(view: 'follow_ups', status: status, counts: counts, rows: rows, meta: meta))
      end

      def interactions(args)
        scope = CustomerInteraction.where(created_at: @window)
        scope = scope.where(kind: args['kind']) if args['kind'].present?
        owner = owner_filter(args)
        scope = owner == :none ? scope.none : scope.where(author_id: owner) if owner
        page, meta = paginate(scope.includes(:customer, :author).order(created_at: :desc, id: :desc), args)
        rows = page.map do |interaction|
          { customer_id: interaction.customer_id, customer: interaction.customer&.name, kind: interaction.kind, at: iso(interaction.created_at),
            by: staff_name(interaction.author), summary: redact(interaction.body, 200), path: paths.customer_path(interaction.customer_id) }
        end
        counts = { interactions: scope.count, by_kind: scope.group(:kind).count, customers: scope.distinct.count(:customer_id) }
        text = "#{range[:from]} to #{range[:to]}: #{counts[:interactions]} interactions logged with #{counts[:customers]} customers" +
               (counts[:by_kind].any? ? " (#{counts[:by_kind].map { |kind, count| "#{kind} #{count}" }.join(', ')})" : '') + '.' +
               (rows.any? ? " Latest: #{rows.first(5).map { |r| "#{r[:customer]} #{r[:kind]} #{r[:at].to_s.first(10)}" }.join('; ')}." : '')
        result(text.truncate(590), range.merge(view: 'interactions', counts: counts, rows: rows, meta: meta,
          note: 'Only interactions staff logged on a customer profile in Rupert. Emails sent by marketing campaigns are not included.'))
      end

      def subscriptions
        result("#{NOT_STORED} Order history is available with view=repeat or customer_lookup.",
          { view: 'subscriptions', stored: false, counts: { active: nil, cancelled: nil, renewing_soon: nil }, rows: [], note: NOT_STORED })
      end
    end
  end
end
