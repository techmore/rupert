# frozen_string_literal: true

module MasterStock
  # Rupert-owned stock pages. Reading needs inventory.read; recording needs
  # inventory.write; setup (sites, links, imports) also needs settings.write.
  class BaseController < AuthenticatedController
    before_action -> { authorize(:module, :inventory_read?) }
    rescue_from MasterStock::Error, with: :master_stock_error
    rescue_from ActiveRecord::StatementInvalid do |error|
      raise error unless %w[SQLite3::BusyException SQLite3::LockedException].include?(error.cause.class.name)

      redirect_back_or_to(master_stock_items_path, alert: 'Stock is busy. Try again; nothing was recorded twice.')
    end

    private

    def require_write!
      authorize(:module, :inventory_write?)
    end

    def require_setup!
      authorize(:module, :inventory_write?)
      authorize(:module, :settings_write?)
    end

    def master_stock_error(error)
      redirect_back_or_to(master_stock_items_path, alert: error.message)
    end

    def sites
      @sites ||= StockSite.active.order(:name).to_a
    end

    # The site in the URL, else the one this person used last, else the site
    # mapped to the primary Shopify location (the shop floor, not a stockroom).
    def selected_site
      @selected_site ||= begin
        site = sites.find { |candidate| candidate.id.to_s == params[:site_id].to_s } ||
          sites.find { |candidate| candidate.id == session[:master_stock_site_id] } ||
          sites.find { |candidate| primary_location_ids.include?(candidate.shopify_location_id) } || sites.first
        session[:master_stock_site_id] = site.id if site
        site
      end
    end

    def primary_location_ids
      Location.where(source: 'shopify', primary_location: true).pluck(:id)
    end

    # Each mapped platform's stored reading for these items at the site:
    # { item_id => { 'shopify' => PushPreview::Row, ... } }. Reads snapshots only.
    def platform_readings(site, item_ids)
      return {} if site.nil? || item_ids.empty?

      site.mapped_platforms.each_with_object({}) do |platform, out|
        MasterStock::PushPreview.new(site: site, platform: platform, item_ids: item_ids).rows.each do |row|
          (out[row.item.id] ||= {})[platform] = row
        end
      end
    end
  end
end
