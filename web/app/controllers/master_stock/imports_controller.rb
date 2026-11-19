# frozen_string_literal: true

module MasterStock
  class ImportsController < BaseController
    before_action :require_setup!

    def create
      site = StockSite.find(params.require(:site_id))
      result = Importer.new(actor: Current.user).call(site: site, platform: params.require(:platform),
        token: params.require(:request_token), seed_balances: params[:seed_balances] == '1')
      message = "#{result.created} items now tracked at #{site.name}"
      message += ", #{result.shopify_links} with an exact Shopify link" if result.shopify_links.positive?
      message += ", #{result.opened} opening counts" if result.opened.positive?
      message += ", #{result.uncounted} still need a count" if result.uncounted.positive?
      message += ", #{result.skipped} already tracked" if result.skipped.positive?
      redirect_to(master_stock_setup_path, notice: "#{message}.")
    end
  end
end
