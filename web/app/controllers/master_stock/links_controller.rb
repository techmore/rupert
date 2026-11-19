# frozen_string_literal: true

module MasterStock
  class LinksController < BaseController
    before_action :require_setup!

    def create
      item = StockItem.find(params.require(:item_id))
      site = StockSite.find(params.require(:site_id))
      platform = params.require(:platform)
      native = normalize(platform, params.require(:native_item_id))
      link = StockItemLink.new(stock_item: item, stock_site: site, platform: platform, native_item_id: native,
        match_source: 'manual', linked_by: Current.user.email)
      if link.save
        ActivityLogger.log('master_stock_link', subject: item, details: "Linked #{MasterStock.platform_label(platform)} #{native} at #{site.name}")
        redirect_to(master_stock_item_path(item), notice: "#{MasterStock.platform_label(platform)} link saved.")
      else
        redirect_to(master_stock_item_path(item), alert: link.errors.full_messages.to_sentence)
      end
    end

    def destroy
      link = StockItemLink.find(params[:id])
      link.destroy!
      ActivityLogger.log('master_stock_link', subject: link.stock_item, details: "Removed #{MasterStock.platform_label(link.platform)} #{link.native_item_id} at #{link.stock_site.name}")
      redirect_to(master_stock_item_path(link.stock_item), notice: 'Link removed. Platform stock was not changed.')
    end

    private

    # Accept a bare Shopify variant number as well as its GID.
    def normalize(platform, value)
      text = value.to_s.strip
      platform == 'shopify' && text.match?(/\A[1-9][0-9]{0,30}\z/) ? "gid://shopify/ProductVariant/#{text}" : text
    end
  end
end
