# frozen_string_literal: true

# Admin CRUD for secret warehouse-sale links shared with vendors.
class WarehouseSharesController < AuthenticatedController
  before_action :authorize_write, only: %i[create update update_tiers destroy]
  before_action :authorize_read, only: :show
  before_action :set_share, only: %i[show update update_tiers destroy]

  # The share's #to_param is its secret token, so all :id params arrive as tokens.
  def set_share
    @share = WarehouseShare.find_by!(token: params[:id])
  end

  def create
    @share = WarehouseShare.new(
      name: params[:name],
      priceMultiplier: params[:priceMultiplier].presence || 1.0
    )
    if @share.save
      redirect_to(warehouse_share_path(@share), notice: 'Vendor link created — copy it and send it.')
    else
      redirect_to(warehouse_path, alert: @share.errors.full_messages.join(', '))
    end
  end

  def show
    @custom_tiers = @share.tiers.order(:minQty)
  end

  def update
    if @share.update(
      name: params[:name],
      priceMultiplier: params[:priceMultiplier].presence || @share.priceMultiplier,
      status: params[:status].presence || @share.status,
      useCustomTiers: params[:useCustomTiers] == '1'
    )
      redirect_to(warehouse_share_path(@share), notice: 'Vendor link updated')
    else
      @custom_tiers = @share.tiers.order(:minQty)
      render(:show, status: :unprocessable_entity)
    end
  end

  def update_tiers
    params.to_unsafe_hash.fetch('tiers', {}).each_value do |attrs|
      if attrs[:_destroy] == '1'
        @share.tiers.find_by(id: attrs[:id])&.destroy
      elsif attrs[:minQty].present?
        tier = @share.tiers.find_by(id: attrs[:id]) || @share.tiers.build
        tier.minQty = attrs[:minQty]
        tier.discountPercent = attrs[:discountPercent]
        tier.save!
      end
    end
    redirect_to(warehouse_share_path(@share), notice: 'Bulk tiers updated')
  rescue ActiveRecord::RecordInvalid => e
    redirect_to(warehouse_share_path(@share), alert: e.record.errors.full_messages.join(', '))
  end

  def destroy
    @share.destroy
    redirect_to(warehouse_path, notice: 'Vendor link deleted')
  end

  private

  def authorize_read
    authorize(:module, :settings_read?)
  end

  def authorize_write
    authorize(:module, :settings_write?)
  end
end
