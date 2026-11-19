# frozen_string_literal: true

module MasterStock
  # Starts tracking items at a site from a stored platform stock read. Creates
  # one Rupert item per native item not yet linked at the site and links it
  # exactly. A C-Trax record carrying a Shopify variant ID that exists in this
  # workspace also gets that Shopify link. Nothing is matched by SKU or name.
  #
  # Optional opening balances are recorded as counts labelled with the source
  # read. Unknown, fractional, negative or stale observations are left uncounted.
  class Importer
    Result = Struct.new(:created, :skipped, :shopify_links, :opened, :uncounted, keyword_init: true)

    def initialize(actor:)
      MasterStock.require_actor!(actor, 'settings.write')
      @actor = actor
    end

    def call(site:, platform:, token:, seed_balances: false)
      raise Error, 'Choose a site from this workspace.' unless site.is_a?(StockSite) && site.tenant_id == Current.tenant_id && site.active
      raise Error, 'Reload the form for a valid request token.' unless token.to_s.match?(/\A[\w-]{1,60}\z/)

      location = site.platform_location(platform) if %w[shopify ctrax].include?(platform)
      raise Error, "Map #{site.name} to a #{MasterStock.platform_label(platform)} location first." unless location

      snapshot = platform == 'ctrax' ? CtraxStockSnapshot.find_by(location: location) : ShopifyStockSnapshot.find_by(location: location)
      raise Error, "No #{MasterStock.platform_label(platform)} stock read for #{location.name} yet. Sync stock first." unless snapshot

      fresh = snapshot.captured_at.between?(PushPreview::FRESH_FOR.ago, Time.current)
      raise Error, 'Opening balances need a stock read from the last hour. Sync stock first.' if seed_balances && !fresh

      result = Result.new(created: 0, skipped: 0, shopify_links: 0, opened: 0, uncounted: 0)
      ledger = Ledger.new(actor: @actor)
      MasterStock.serialized do
        records(platform, snapshot).each do |native_id, attributes, quantity, website_variant|
          if StockItemLink.exists?(stock_site: site, platform: platform, native_item_id: native_id)
            result.skipped += 1
            next
          end
          item = StockItem.create!(attributes.merge(tenant_id: Current.tenant_id, created_by: @actor.email))
          link!(item, site, platform, native_id, 'import')
          result.created += 1
          if website_variant && link!(item, site, 'shopify', website_variant, 'ctrax_website_variant')
            result.shopify_links += 1
          end
          next unless seed_balances

          if quantity.is_a?(Integer) && quantity.between?(0, MasterStock::MAX_UNITS)
            ledger.record(kind: 'count', item: item, site: site, quantity: quantity, token: "#{token}-#{platform}#{native_id.split("/").last}",
              reference: "Opening count from #{MasterStock.platform_label(platform)} read #{snapshot.captured_at.utc.iso8601}",
              note: 'Seeded from a platform stock read, not a physical count.')
            result.opened += 1
          else
            result.uncounted += 1
          end
        end
      end
      ActivityLogger.log('master_stock_import', subject: site, actor: @actor,
        details: "#{result.created} items from #{MasterStock.platform_label(platform)} (#{result.opened} opening counts)")
      result
    rescue ActiveRecord::RecordInvalid => e
      raise Error, e.record.errors.full_messages.to_sentence
    end

    private

    def records(platform, snapshot)
      if platform == 'ctrax'
        variants = ShopifyVariant.where(id: snapshot.records.filter_map { |row| shopify_gid(row['website_variant_id']) }).pluck(:id).to_set
        snapshot.records.filter_map do |row|
          id = row['id'].to_s
          next unless id.match?(/\A[1-9][0-9]{0,18}\z/) && row['manage_stock']

          quantity = row['quantity'].to_s.match?(/\A\d{1,9}(?:\.0+)?\z/) ? row['quantity'].to_s.to_i : nil
          gid = shopify_gid(row['website_variant_id'])
          [id, { name: (row['name'].presence || row['product_name'].presence || "C-Trax variant #{id}").truncate(255),
                 sku: row['sku'], barcode: row['barcode'] }, quantity, variants.include?(gid) ? gid : nil]
        end
      else
        variants = ShopifyVariant.where(id: snapshot.records.map { |row| row['id'] }).includes(:product).index_by(&:id)
        snapshot.records.filter_map do |row|
          variant = variants[row['id']]
          next unless variant && variant.tracked && variant.catalog_present != false

          name = [variant.product&.title, (variant.title unless variant.title == 'Default Title')].compact.join(' · ').presence || variant.id
          quantity = row['on_hand'].is_a?(Integer) ? row['on_hand'] : nil
          [variant.id, { name: name.truncate(255), sku: variant.sku, barcode: variant.barcode }, quantity, nil]
        end
      end
    end

    def link!(item, site, platform, native_id, source)
      return false if site.public_send("#{platform}_location_id").blank?
      return false if StockItemLink.exists?(stock_site: site, platform: platform, native_item_id: native_id)

      StockItemLink.create!(tenant_id: Current.tenant_id, stock_item: item, stock_site: site, platform: platform,
        native_item_id: native_id, match_source: source, linked_by: @actor.email)
    end

    def shopify_gid(value)
      id = value.to_s.split('/').last
      id.to_s.match?(/\A[1-9][0-9]{0,30}\z/) ? "gid://shopify/ProductVariant/#{id}" : nil
    end
  end
end
