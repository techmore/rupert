# frozen_string_literal: true

class InventoryCountsController < AuthenticatedController
  before_action :require_inventory_write, except: [:index, :show]

  def index
    @counts = InventoryCount.by_status(params[:status]).recent(30)
  end

  def show
    @count = InventoryCount.find(params[:id])
  end

  def new
    @count = InventoryCount.new(countedAt: Time.current, locationId: params[:location_id])
    @locations = Location.order(name: :asc).limit(200)
    @skus = SkuLink.order(:sku).limit(500).pluck(:sku)
    @prepared = params[:prepared] != "0"

    if @prepared
      @count.items = prepared_sheet_items
    else
      @count.items.build
    end
  end

  def create
    @count = InventoryCount.new(count_params.merge(createdBy: Current.user.email))
    build_items(@count)
    if @count.save
      redirect_to(inventory_count_path(@count), notice: "Draft count created.")
    else
      @locations = Location.order(name: :asc).limit(200)
      @skus = SkuLink.order(:sku).limit(500).pluck(:sku)
      render(:new, status: :unprocessable_entity)
    end
  end

  def edit
    @count = InventoryCount.find(params[:id])
    @locations = Location.order(name: :asc).limit(200)
    @skus = SkuLink.order(:sku).limit(500).pluck(:sku)
  end

  def update
    @count = InventoryCount.find(params[:id])
    @count.assign_attributes(count_params)
    @count.items.destroy_all
    build_items(@count)
    if @count.save
      redirect_to(inventory_count_path(@count), notice: "Count updated.")
    else
      @locations = Location.order(name: :asc).limit(200)
      @skus = SkuLink.order(:sku).limit(500).pluck(:sku)
      render(:edit, status: :unprocessable_entity)
    end
  end

  def submit
    @count = InventoryCount.find(params[:id])
    @count.snapshot_previous!
    @count.submit!
    redirect_to(inventory_count_path(@count), notice: "Count submitted for approval.")
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: "Only draft counts can be submitted.")
  end

  def approve
    @count = InventoryCount.find(params[:id])
    InventoryCount.transaction do
      @count.approve!
      @count.apply_override!(actor: Current.user.email)
      @count.update!(approvedAt: Time.current)
    end
    redirect_to(inventory_count_path(@count), notice: "Count approved — inventory totals overridden.")
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: "Only pending counts can be approved.")
  rescue StandardError => e
    redirect_to(inventory_count_path(@count), alert: "Approval failed: #{e.message}")
  end

  def reject
    @count = InventoryCount.find(params[:id])
    @count.reject!
    redirect_to(inventory_count_path(@count), notice: "Count rejected.")
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: "Only pending counts can be rejected.")
  end

  def reopen
    @count = InventoryCount.find(params[:id])
    @count.reopen!
    redirect_to(inventory_count_path(@count), notice: "Count reopened as a draft — edit and resubmit it.")
  rescue AASM::InvalidTransition
    redirect_to(inventory_count_path(@count), alert: "Only rejected counts can be reopened.")
  end

  def destroy
    @count = InventoryCount.find(params[:id])
    @count.destroy!
    redirect_to(inventory_counts_path, notice: "Draft deleted.")
  end

  private

  def require_inventory_write
    return if Current.user.can?("inventory.write")

    redirect_to(inventory_counts_path, alert: "You don't have permission to modify inventory counts.")
  end

  def count_params
    params.require(:inventory_count).permit(:locationId, :note, :countedAt)
  end

  # A "prepared sheet": every SKU with a Shopify variant and its current system
  # total, so a counter only has to fill in the manual override column (what's
  # actually on hand) and submit the whole sheet at once. Includes SKUs that
  # aren't yet linked to Square so the sheet is complete.
  def prepared_sheet_items
    rows = []
    SkuLink.includes(shopify_variant: :product).order(:sku).find_each do |link|
      variant = link.shopify_variant
      next if variant.nil?

      rows << InventoryCountItem.new(
        sku: link.sku,
        shopifyVariantId: link.shopifyVariantId,
        squareVariationId: link.squareVariationId,
        quantity: InventoryLevel.total_for_variant(link.shopifyVariantId),
      )
    end
    rows
  end

  def build_items(count)
    Array(params[:items]).each do |row|
      sku = row[:sku].to_s.strip
      next if sku.blank? && row[:quantity].to_s.blank?

      count.items.build(sku: sku, quantity: row[:quantity].to_i)
    end
  end
end
