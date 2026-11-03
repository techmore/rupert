# frozen_string_literal: true

module MasterStock
  # Dry run of Rupert as the primary inventory: for each linked item at a site,
  # compares Rupert on-hand with the platform's latest stored observation and
  # describes the exact write Rupert would send. Reads stored snapshots only;
  # it never contacts a platform and never changes stock.
  class PushPreview
    FRESH_FOR = 1.hour
    PLATFORM_WRITES = {
      'shopify' => 'Set on hand with inventorySetQuantities (changeFromQuantity guard, idempotency key).',
      'ctrax' => 'Remove units with an inventory adjustment and a Rupert marker. Adding units is not verified.',
      'square' => 'Inventory ADJUSTMENT (never a computed physical count).'
    }.freeze

    Row = Struct.new(:link, :item, :balance, :observed, :observed_at, :target, :change, :status, :action, :reasons,
      :payload, keyword_init: true)

    attr_reader :site, :platform

    # item_ids: limit the preview to these Rupert items (the stock list and an
    # item page show platform numbers for a few items without building them all).
    def initialize(site:, platform:, at: Time.current, item_ids: nil)
      raise ArgumentError, 'unknown platform' unless StockSite::PLATFORMS.include?(platform)

      @site = site
      @platform = platform
      @at = at
      @item_ids = item_ids
      @location = site.platform_location(platform)
    end

    # Would-change rows first, largest change first, then blocked, then matching.
    def rows
      @rows ||= begin
        links = site.links.where(platform: platform).includes(:stock_item).order(:id)
        links = links.where(stock_item_id: @item_ids) if @item_ids
        links = links.to_a
        balances = StockBalance.where(stock_site: site, stock_item_id: links.map(&:stock_item_id)).index_by(&:stock_item_id)
        links.map { |link| build(link, balances[link.stock_item_id]) }
          .sort_by { |row| [{ 'change' => 0, 'blocked' => 1, 'in_sync' => 2 }.fetch(row.status), -row.change.to_i.abs, row.item.name.downcase] }
      end
    end

    def rows_by_item = rows.index_by { |row| row.item.id }

    # A change this large is more likely a miscount or a missing sale than real stock.
    def self.large_change?(row)
      return false unless row.change && row.observed

      row.change.abs >= 10 && row.change.abs * 2 >= [row.observed.abs, row.target.to_i].max
    end

    def summary
      counts = rows.group_by(&:status).transform_values(&:size)
      { change: counts.fetch('change', 0), blocked: counts.fetch('blocked', 0), in_sync: counts.fetch('in_sync', 0),
        units_down: rows.select { |row| row.status == 'change' && row.change.negative? }.sum { |row| -row.change },
        units_up: rows.select { |row| row.status == 'change' && row.change.positive? }.sum(&:change) }
    end

    def location = @location

    def snapshot_at
      case platform
      when 'shopify' then shopify_snapshot&.captured_at
      when 'ctrax' then ctrax_snapshot&.captured_at
      when 'square' then InventoryLevel.where(source: 'square', locationId: @location&.id).maximum(:updatedAt)
      end
    end

    def platform_blocker
      return "#{site.name} has no #{MasterStock.platform_label(platform)} location mapped." unless @location
      return "The mapped #{MasterStock.platform_label(platform)} location is inactive." if @location.active == false
      return 'Square writes are frozen for maintenance (Stock push guard).' if platform == 'square' && PlatformPushGuard.frozen?('square')

      nil
    end

    private

    def build(link, balance)
      item = link.stock_item
      reasons = []
      observed, observed_at, extra = observation(link, reasons)
      target = balance&.on_hand
      reasons << 'Count this item in Rupert first.' if target.nil?
      reasons << platform_blocker if platform_blocker
      reasons << 'Platform stock is unknown.' if observed.nil? && reasons.empty?
      change = target && observed ? target - observed : nil
      status = if reasons.any? then 'blocked'
      elsif change.zero? then 'in_sync'
      elsif platform == 'ctrax' && change.positive?
        reasons << "Adding units in C-Trax is not verified. Enter +#{change} in C-Trax by hand."
        'blocked'
      else 'change'
      end
      Row.new(link: link, item: item, balance: balance, observed: observed, observed_at: observed_at, target: target,
        change: change, status: status, reasons: reasons, action: action_text(observed, target, change, status),
        payload: status == 'change' ? payload(link, balance, observed, target, change, extra) : nil)
    end

    def observation(link, reasons)
      case platform
      when 'shopify'
        snapshot = shopify_snapshot
        record = records_by_id(snapshot)[link.native_item_id]
        return missing(reasons, snapshot) unless record

        quantity = record['on_hand']
        reasons << 'Shopify on-hand is unknown.' unless quantity.is_a?(Integer)
        stale!(reasons, snapshot.captured_at)
        [quantity.is_a?(Integer) ? quantity : nil, snapshot.captured_at, record]
      when 'ctrax'
        snapshot = ctrax_snapshot
        record = records_by_id(snapshot)[link.native_item_id]
        return missing(reasons, snapshot) unless record

        raw = record['quantity']
        reasons << 'C-Trax does not track stock for this variant.' unless record['manage_stock']
        quantity = raw.to_s.match?(/\A-?\d{1,12}(?:\.0+)?\z/) ? raw.to_s.to_i : nil
        reasons << (raw.nil? ? 'C-Trax stock is unknown.' : 'C-Trax stock is not a whole number.') if quantity.nil?
        stale!(reasons, snapshot.captured_at)
        [quantity, snapshot.captured_at, record.merge('store_id' => snapshot.store_id)]
      when 'square'
        level = InventoryLevel.find_by(source: 'square', locationId: @location&.id, squareVariationId: link.native_item_id)
        unless level
          reasons << 'No stored Square stock for this item at this location.'
          return [nil, nil, nil]
        end
        stale!(reasons, level.updatedAt)
        [level.sourceQuantity || level.quantity, level.updatedAt, nil]
      end
    end

    def missing(reasons, snapshot)
      reasons << (snapshot ? "This item is not in the latest #{MasterStock.platform_label(platform)} read for this location." : "No #{MasterStock.platform_label(platform)} stock read for this location yet.")
      [nil, snapshot&.captured_at, nil]
    end

    def stale!(reasons, at)
      return if at && at <= @at && at >= @at - FRESH_FOR

      reasons << "#{MasterStock.platform_label(platform)} stock was read more than an hour ago. Refresh it before pushing."
    end

    def action_text(observed, target, change, status)
      label = MasterStock.platform_label(platform)
      case status
      when 'in_sync' then "#{label} already shows #{target}."
      when 'change'
        case platform
        when 'shopify' then "Set Shopify on hand from #{observed} to #{target}."
        when 'ctrax' then "Remove #{-change} in C-Trax (#{observed} → #{target})."
        when 'square' then "#{change.positive? ? 'Add' : 'Remove'} #{change.abs} in Square (#{observed} → #{target})."
        end
      else
        observed && target ? "#{label} #{observed} → Rupert #{target} (not pushed)." : 'Not pushed.'
      end
    end

    # The request body Rupert would send, without credentials or idempotency
    # keys (those are assigned when a live push is queued).
    def payload(link, balance, observed, target, change, extra)
      case platform
      when 'shopify'
        { 'mutation' => 'inventorySetQuantities',
          'input' => { 'name' => 'on_hand', 'reason' => 'correction',
                       'referenceDocumentUri' => "gid://rupert/StockBalance/#{balance.id}",
                       'quantities' => [{ 'inventoryItemId' => extra['inventory_item_id'], 'locationId' => @location.externalId,
                                          'quantity' => target, 'changeFromQuantity' => observed }] } }
      when 'ctrax'
        { 'method' => 'POST', 'path' => "/api/v1/stores/#{extra['store_id']}/productVariants/#{link.native_item_id}/inventoryAdjustments",
          'body' => { 'action' => 'remove', 'quantity' => -change, 'reason' => 'other',
                      'comments' => "Rupert stock balance #{balance.id} variant #{link.native_item_id}" } }
      when 'square'
        { 'method' => 'POST', 'path' => '/v2/inventory/changes/batch-create',
          'body' => { 'changes' => [{ 'type' => 'ADJUSTMENT', 'adjustment' => {
            'from_state' => change.positive? ? 'NONE' : 'IN_STOCK', 'to_state' => change.positive? ? 'IN_STOCK' : 'NONE',
            'location_id' => @location.externalId, 'catalog_object_id' => link.native_item_id, 'quantity' => change.abs.to_s
          } }] } }
      end
    end

    def records_by_id(snapshot)
      @records_by_id ||= {}
      @records_by_id[snapshot&.id] ||= snapshot ? snapshot.records.index_by { |row| row['id'].to_s } : {}
    end

    def shopify_snapshot
      return @shopify_snapshot if defined?(@shopify_snapshot)

      @shopify_snapshot = @location && ShopifyStockSnapshot.find_by(location_id: @location.id)
    end

    def ctrax_snapshot
      return @ctrax_snapshot if defined?(@ctrax_snapshot)

      @ctrax_snapshot = @location && CtraxStockSnapshot.find_by(location_id: @location.id)
    end
  end
end
