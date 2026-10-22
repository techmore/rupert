# frozen_string_literal: true

module Mcp
  module Tools
    # "What moved yesterday?", "show movements for Calm Gummies this week",
    # "where did the 20 tincture bottles go?" The inventory movement ledger
    # (the Inventory > Movements page) and the bulk material ledger.
    class StockMovements < Tool
      LEDGERS = %w[items bulk].freeze
      DIRECTIONS = %w[in out set].freeze
      BULK_KINDS = %w[receipt consume adjustment].freeze

      tool 'stock_movements',
        title: 'Stock movements',
        description: 'Stock movement history: what moved, when, by how much and why, for Shopify and Square stock levels and ' \
                     'bulk material lots. Newest first. ledger items (default, the Inventory > Movements ' \
                     'page): each change to a Shopify or Square stock level with SKU, item name, source (shopify / square ' \
                     'sync, negative-fix, size-derive, maintain...), direction, change, quantity before and after, reason and ' \
                     'reference, plus net change per SKU and counts per source. ledger bulk: bulk material lots (herbs, oils ' \
                     'by weight) received, consumed and adjusted, in grams, with who recorded it. Filter by SKU or item name, ' \
                     'source, direction, and dates. Answers "what moved yesterday", "movements for Calm Gummies this week", ' \
                     '"when was the sleep tincture last adjusted", "how much lavender did we use". Not here: which person changed ' \
                     'a Shopify or Square level (item movements only say system or user), sales (use sales_summary), current ' \
                     'levels (use inventory_search), and purchase orders (use purchase_orders). Read-only.',
        scope: 'inventory:read'

      input_schema(
        type: 'object',
        properties: {
          ledger: { type: 'string', enum: LEDGERS, description: 'items (default) or bulk.' },
          query: { type: 'string', maxLength: 100, description: 'SKU, item or material name fragment, e.g. "TEA-50" or "Calm Gummies".' },
          source: { type: 'string', maxLength: 40, description: 'items ledger: shopify, square, negative-fix, size-derive, maintain...' },
          direction: { type: 'string', enum: DIRECTIONS + BULK_KINDS, description: 'items: in, out or set (a sync). bulk: receipt, consume or adjustment.' },
          from: DATE_PROPERTY.merge(description: 'First day (inclusive). Default 7 days ago.'),
          to: DATE_PROPERTY.merge(description: 'Last day (inclusive). Default today.'),
          **PAGE_PROPERTIES
        },
        additionalProperties: false
      )

      def call(args)
        from, to = date_range(args, default_from: Date.current - 6, max_days: 400)
        window = from.in_time_zone.beginning_of_day...(to + 1).in_time_zone.beginning_of_day
        args['ledger'] == 'bulk' ? bulk(args, from, to, window) : items(args, from, to, window)
      end

      private

      def like(text) = "%#{InventoryMovement.sanitize_sql_like(text.to_s.strip, '!')}%"

      # ---- item ledger ----

      def items(args, from, to, window)
        scope = InventoryMovement.where(tenant_id: tenant.id, createdAt: window)
        scope = scope.where(source: args['source'].to_s.strip) if args['source'].present?
        scope = scope.where(direction: args['direction']) if DIRECTIONS.include?(args['direction'])
        scope = scope.where("sku LIKE ? ESCAPE '!' OR sku IN (?)", like(args['query']), skus_named(args['query'])) if args['query'].present?
        rows, meta = paginate(scope.order(createdAt: :desc, id: :desc), args)
        names = names_for(rows.map(&:sku))
        net = scope.where.not(sku: nil).group(:sku).order(Arel.sql('ABS(SUM(delta)) DESC')).limit(10).sum(:delta)
        net_names = names_for(net.keys)
        data = {
          ledger: 'items', from: from.iso8601, to: to.iso8601, total: scope.count, counts_by_source: scope.group(:source).count,
          net_change_by_sku: net.map { |sku, delta| { sku: sku, name: net_names.dig(sku, :name), net_change: delta.to_i } },
          rows: rows.map { |row| item_row(row, names) }, meta: meta,
          note: 'Shopify and Square are separate stock pools; a sync row (direction set) records the level the platform reported.'
        }
        result(item_summary(data), data)
      end

      def skus_named(query)
        pattern = like(query)
        shopify = ShopifyVariant.joins(:product)
          .where(%("ShopifyVariant"."title" LIKE :q ESCAPE '!' OR "ShopifyProduct"."title" LIKE :q ESCAPE '!'), q: pattern)
        square = SquareVariation.where("name LIKE ? ESCAPE '!'", pattern)
        (shopify.limit(200).pluck(:sku) + square.limit(200).pluck(:sku)).compact.uniq.presence || ['']
      rescue ActiveRecord::StatementInvalid
        ['']
      end

      def names_for(skus)
        skus = skus.compact.uniq
        return {} if skus.empty?

        names = {}
        ShopifyVariant.where(sku: skus).includes(:product).find_each do |variant|
          names[variant.sku] ||= { name: [variant.product&.title, variant.title].compact.reject { |part| part == 'Default Title' }.join(' — ') }
        end
        SquareVariation.where(sku: skus).find_each { |variation| names[variation.sku] ||= { name: variation.name } }
        names
      end

      def item_row(row, names)
        { at: iso(row.createdAt), sku: row.sku, name: names.dig(row.sku, :name), source: row.source, direction: row.direction,
          change: row.delta, before: row.quantityBefore, after: row.quantityAfter, reason: ActivityLog.scrub(row.reason, max: 160),
          reference: ActivityLog.scrub(row.reference, max: 80), actor: row.actor }.compact
      end

      def item_summary(data)
        head = "#{data[:total]} stock movements #{data[:from]} to #{data[:to]}" +
               (data[:counts_by_source].any? ? " (#{data[:counts_by_source].map { |source, count| "#{source} #{count}" }.join(', ')})" : '')
        return "#{head}." if data[:rows].empty?

        net = data[:net_change_by_sku].first(5).map { |row| "#{row[:name] || row[:sku]} #{format('%+d', row[:net_change])}" }
        latest = data[:rows].first(4).map { |row| "#{row[:at]&.first(16)&.tr('T', ' ')} #{row[:name] || row[:sku]} #{format('%+d', row[:change].to_i)} (#{row[:source]})" }
        "#{head}. Biggest net changes: #{net.join(', ')}. Latest: #{latest.join('; ')}".first(600)
      end

      # ---- bulk ledger ----

      def bulk(args, from, to, window)
        scope = BulkMovement.where(tenant_id: tenant.id, created_at: window).joins(bulk_lot: :bulk_material).includes(bulk_lot: :bulk_material)
        scope = scope.where(kind: args['direction']) if BULK_KINDS.include?(args['direction'])
        if args['query'].present?
          scope = scope.where("bulk_materials.name LIKE :q ESCAPE '!' OR bulk_lots.code LIKE :q ESCAPE '!' OR bulk_movements.reference LIKE :q ESCAPE '!'", q: like(args['query']))
        end
        rows, meta = paginate(scope.order(created_at: :desc, id: :desc), args)
        people = people_for(rows.map(&:created_by))
        totals = scope.group('bulk_materials.name', 'bulk_movements.kind').sum(:delta_mg)
        by_material = totals.each_with_object({}) do |((material, kind), mg), memo|
          (memo[material] ||= { material: material, received_g: 0.0, consumed_g: 0.0, adjusted_g: 0.0 })[bulk_key(kind)] += kind == 'adjustment' ? grams(mg) : grams(mg).abs
        end
        data = { ledger: 'bulk', from: from.iso8601, to: to.iso8601, total: scope.count, by_material: by_material.values,
                 rows: rows.map { |row| bulk_row(row, people) }, meta: meta, note: 'Weights in grams (stored in milligrams).' }
        result(bulk_summary(data), data)
      end

      def bulk_key(kind) = { 'receipt' => :received_g, 'consume' => :consumed_g }.fetch(kind, :adjusted_g)

      def grams(milligrams) = (milligrams.to_i / 1000.0).round(3)

      # Bulk rows store the recorder's email; show their name only.
      def people_for(values)
        users = User.where(tenant_id: tenant.id, email: values.compact.uniq).index_by(&:email)
        values.compact.uniq.index_with { |value| users[value]&.display_name || ActivityLog.person(value) }
      end

      def bulk_row(row, people)
        lot = row.bulk_lot
        { at: iso(row.created_at), material: lot.bulk_material.name, lot: lot.code, kind: row.kind, change_g: grams(row.delta_mg),
          entered: "#{row.input_quantity} #{row.input_unit}", reference: ActivityLog.scrub(row.reference, max: 120),
          recorded_by: people[row.created_by], lot_balance_g: grams(lot.balance_mg) }.compact
      end

      def bulk_summary(data)
        head = "#{data[:total]} bulk material movements #{data[:from]} to #{data[:to]}"
        return "#{head}." if data[:rows].empty?

        materials = data[:by_material].first(5).map { |row| "#{row[:material]} in #{row[:received_g]}g, used #{row[:consumed_g]}g" }
        "#{head}. #{materials.join('; ')}.".first(600)
      end
    end
  end
end
