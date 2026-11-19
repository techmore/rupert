# frozen_string_literal: true

module MasterStock
  class SetupController < BaseController
    def show
      @all_sites = StockSite.order(:name).to_a
      @locations = Location.where(source: StockSite::PLATFORMS, active: true).order(:source, :name).group_by(&:source)
      @snapshots = { 'shopify' => ShopifyStockSnapshot.all.index_by(&:location_id), 'ctrax' => CtraxStockSnapshot.all.index_by(&:location_id) }
      @can_setup = Current.user.can?('settings.write') && Current.user.can?('inventory.write')
      @token = SecureRandom.hex(16)
    end
  end
end
