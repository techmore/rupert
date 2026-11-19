# frozen_string_literal: true

module MasterStock
  # Dry run only. Reads stored platform snapshots; sends nothing.
  class PushPreviewsController < BaseController
    def show
      @site = selected_site
      @platform = StockSite::PLATFORMS.include?(params[:platform]) ? params[:platform] : (@site&.mapped_platforms&.first || 'shopify')
      @preview = PushPreview.new(site: @site, platform: @platform) if @site
      @status = %w[change blocked in_sync].include?(params[:status]) ? params[:status] : nil
      @rows = @preview ? @preview.rows.select { |row| @status.nil? || row.status == @status } : []
    end
  end
end
