# frozen_string_literal: true

module MasterStock
  class ItemsController < BaseController
    before_action :require_write!, only: %i[new create]

    def index
      @site = selected_site
      @query = params[:q].to_s.strip.first(255)
      scope = StockItem.active.lookup(@query)
      scope = scope.where(id: StockItemLink.where(stock_site: @site).select(:stock_item_id))
        .or(scope.where(id: StockBalance.where(stock_site: @site).select(:stock_item_id))) if @site && params[:all] != '1'
      @pagy, @items = pagy(:offset, scope.order(:name, :id), limit: 50)
      @balances = @site ? StockBalance.where(stock_site: @site, stock_item_id: @items.map(&:id)).index_by(&:stock_item_id) : {}
      @exact = @query.present? && @items.size == 1 && (@items.first.sku == @query || @items.first.barcode == @query)
    end

    def show
      @item = StockItem.find(params[:id])
      @balances = @item.balances.includes(:stock_site).index_by(&:stock_site_id)
      @links = @item.links.includes(:stock_site).order(:stock_site_id, :platform)
      @entries = @item.ledger_entries.includes(:stock_site).newest_first.limit(50)
      @can_setup = Current.user.can?('settings.write') && Current.user.can?('inventory.write')
    end

    def new
      @item = StockItem.new
    end

    def create
      @item = StockItem.new(params.require(:stock_item).permit(:name, :sku, :barcode).merge(created_by: Current.user.email))
      if @item.save
        redirect_to(master_stock_item_path(@item), notice: 'Item added. Count it at a site to start its Rupert stock.')
      else
        render(:new, status: :unprocessable_entity)
      end
    end
  end
end
