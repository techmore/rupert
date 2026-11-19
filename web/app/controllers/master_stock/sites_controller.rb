# frozen_string_literal: true

module MasterStock
  class SitesController < BaseController
    before_action :require_setup!

    def create
      site = StockSite.new(site_params)
      if site.save
        ActivityLogger.log('master_stock_site', subject: site, details: "Added Rupert site #{site.name}")
        redirect_to(master_stock_setup_path, notice: "#{site.name} added.")
      else
        redirect_to(master_stock_setup_path, alert: site.errors.full_messages.to_sentence)
      end
    end

    def update
      site = StockSite.find(params[:id])
      changing = site_params.slice(*StockSite::PLATFORMS.map { |platform| "#{platform}_location_id" }).to_h.any? { |key, value| site.public_send(key).to_s != value.to_s }
      if changing && site.links.exists?
        return redirect_to(master_stock_setup_path, alert: "Remove #{site.name}'s platform links before changing its locations.")
      end

      if site.update(site_params)
        ActivityLogger.log('master_stock_site', subject: site, details: "Updated Rupert site #{site.name}")
        redirect_to(master_stock_setup_path, notice: "#{site.name} saved.")
      else
        redirect_to(master_stock_setup_path, alert: site.errors.full_messages.to_sentence)
      end
    end

    private

    def site_params
      params.require(:stock_site).permit(:name, :active, :shopify_location_id, :ctrax_location_id, :square_location_id)
        .to_h.transform_values { |value| value.presence }
        .tap { |attrs| attrs['active'] = attrs['active'] != '0' if attrs.key?('active') }
    end
  end
end
