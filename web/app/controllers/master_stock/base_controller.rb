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

    def selected_site
      @selected_site ||= sites.find { |site| site.id.to_s == params[:site_id].to_s } || sites.first
    end
  end
end
