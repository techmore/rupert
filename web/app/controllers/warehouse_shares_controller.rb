# frozen_string_literal: true

# Admin CRUD for secret warehouse-sale links shared with vendors.
class WarehouseSharesController < AuthenticatedController
  def create
    @share = WarehouseShare.new(
      name: params[:name],
      priceMultiplier: params[:priceMultiplier].presence || 1.0,
    )
    if @share.save
      redirect_to(warehouse_share_path(@share), notice: "Vendor link created — copy it and send it.")
    else
      redirect_to(warehouse_path, alert: @share.errors.full_messages.join(", "))
    end
  end

  def show
    @share = WarehouseShare.find(params[:id])
    @custom_tiers = @share.tiers.order(:minQty)
  end

  def update
    @share = WarehouseShare.find(params[:id])
    if @share.update(
      name: params[:name],
      priceMultiplier: params[:priceMultiplier].presence || @share.priceMultiplier,
      status: params[:status].presence || @share.status,
      useCustomTiers: params[:useCustomTiers] == "1",
    )
      redirect_to(warehouse_share_path(@share), notice: "Vendor link updated")
    else
      @custom_tiers = @share.tiers.order(:minQty)
      render(:show, status: :unprocessable_entity)
    end
  end

  def update_tiers
    @share = WarehouseShare.find(params[:id])
    params[:tiers].to_h.each_value do |attrs|
      if attrs[:_destroy] == "1"
        @share.tiers.find_by(id: attrs[:id])&.destroy
      elsif attrs[:minQty].present?
        tier = @share.tiers.find_by(id: attrs[:id]) || @share.tiers.build
        tier.minQty = attrs[:minQty]
        tier.discountPercent = attrs[:discountPercent]
        tier.save!
      end
    end
    redirect_to(warehouse_share_path(@share), notice: "Bulk tiers updated")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to(warehouse_share_path(@share), alert: e.record.errors.full_messages.join(", "))
  end

  def destroy
    @share = WarehouseShare.find(params[:id])
    @share.destroy
    redirect_to(warehouse_path, notice: "Vendor link deleted")
  end
end
