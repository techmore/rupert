# frozen_string_literal: true

require 'csv'

module MasterStock
  class MovementsController < BaseController
    before_action :require_write!, only: %i[new create]

    def index
      scope = StockLedgerEntry.includes(:stock_item, :stock_site).newest_first
      scope = scope.where(stock_site_id: params[:site_id]) if params[:site_id].present?
      scope = scope.where(stock_item_id: params[:item_id]) if params[:item_id].present?
      scope = scope.where(kind: params[:kind]) if StockLedgerEntry::KINDS.include?(params[:kind])
      @item = StockItem.find_by(id: params[:item_id]) if params[:item_id].present?
      respond_to do |format|
        format.html { @pagy, @entries = pagy(:offset, scope, limit: 50) }
        format.csv do
          log_export('Rupert stock ledger')
          send_data(csv(scope.limit(50_000)), filename: "rupert-stock-ledger-#{Date.current.iso8601}.csv", type: 'text/csv')
        end
      end
    end

    def new
      @kind = StockLedgerEntry::STAFF_KINDS.include?(params[:kind]) ? params[:kind] : 'count'
      @item = StockItem.active.find(params[:item_id])
      @site = selected_site
      raise MasterStock::Error, 'Add a Rupert site in Setup first.' unless @site

      @balance = StockBalance.find_by(stock_item: @item, stock_site: @site)
      @token = SecureRandom.uuid
      @values = {}
    end

    def create
      attrs = params.require(:movement).permit(:kind, :item_id, :site_id, :quantity, :reason, :note, :reference, :destination_site_id)
      @kind = attrs[:kind]
      @item = StockItem.find(attrs[:item_id])
      @site = StockSite.find(attrs[:site_id])
      @token = params.require(:request_token)
      destination = StockSite.find_by(id: attrs[:destination_site_id]) if attrs[:destination_site_id].present?
      result = Ledger.new(actor: Current.user).record(kind: @kind, item: @item, site: @site, quantity: attrs[:quantity],
        reason: attrs[:reason], note: attrs[:note], reference: attrs[:reference], destination_site: destination, token: @token)
      entry = result.entry
      notice = "#{entry.kind_label}: #{@item.name} at #{@site.name} is now #{result.entries.find { |e| e.stock_site_id == @site.id }.quantity_after}."
      notice += ' (Already recorded; nothing was added twice.)' if result.replayed
      redirect_to(master_stock_items_path(site_id: @site.id, q: params[:return_q].presence), notice: notice)
    rescue MasterStock::Error => e
      @error = e.message
      @balance = StockBalance.find_by(stock_item: @item, stock_site: @site)
      @values = attrs.to_h
      @kind = 'count' unless StockLedgerEntry::STAFF_KINDS.include?(@kind)
      render(:new, status: :unprocessable_entity)
    end

    private

    def csv(scope)
      safe = ->(value) { value.is_a?(String) ? FinanceHelper.csv_safe(value) : value }
      CSV.generate do |out|
        out << ['Recorded at (UTC)', 'Site', 'Item', 'SKU', 'Kind', 'Change', 'Before', 'After', 'Reason', 'Reference', 'Note', 'Origin', 'Recorded by', 'Transfer group']
        scope.find_each(order: :desc) do |entry|
          out << [entry.created_at.utc.iso8601, entry.stock_site.name, entry.stock_item.name, entry.stock_item.sku, entry.kind_label,
                  entry.delta, entry.quantity_before, entry.quantity_after, StockLedgerEntry::REASONS[entry.reason], entry.reference,
                  entry.note, entry.origin, entry.actor, entry.transfer_group].map(&safe)
        end
      end
    end
  end
end
