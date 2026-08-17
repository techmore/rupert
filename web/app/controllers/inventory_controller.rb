# frozen_string_literal: true

require "csv"
require "set"

class InventoryController < AuthenticatedController
  before_action :authorize_read, only: [:index, :movements, :pdf, :recommended_skus]
  before_action :authorize_fix, only: [:fix_negative, :fix_all_negative]

  def index
    @q = params[:q].to_s.strip
    @products = ShopifyProduct.order(title: :asc).limit(40)
    if @q.present?
      @products = @products.where(
        "title LIKE ? OR id IN (SELECT \"productId\" FROM \"ShopifyVariant\" WHERE sku LIKE ?)",
        "%#{@q}%",
        "%#{@q}%",
      )
    end
    @products = @products.includes(variants: [{ sku_links: { square_variation: :levels } }, :levels])
    @variant_qtys = variant_quantity_map(@products)
    @negative = NegativeInventory.summary
    @shared_skus = DataCache.fetch("inventory/shared_skus") { shared_sku_set }
  end

  # GET /inventory/movements — the full inventory movement ledger: every
  # quantity change (source, reason, actor, before → after) with filters.
  def movements
    scope = InventoryMovement.includes(:sync_run).order(createdAt: :desc)
    scope = scope.where(source: params[:source]) if params[:source].present?
    if (q = params[:q].to_s.strip).present?
      scope = scope.where("sku ILIKE ?", "%#{q}%")
    end
    days = params[:days].to_i
    days = 30 unless (1..365).cover?(days)
    scope = scope.where("\"createdAt\" >= ?", days.days.ago)
    @pagy, @movements = pagy(scope, items: 50)
    @names = movement_names(@movements)
    @sources = InventoryMovement.unscoped.where(tenant_id: Current.tenant_id)
      .distinct.order(:source).pluck(:source)
  end

  # GET /inventory/recommended_skus — full-catalog Shopify vs Square SKU
  # matching report as CSV (every variant: Shopify SKU, Square SKU, status,
  # and proposed unique SKUs for duplicates). Plan-only: applying requires
  # updating Shopify + Square and re-linking (see ops:sku_remediation_plan).
  def recommended_skus
    send_data SkuMatchReport.csv,
      filename: "sku-report-#{Date.current.iso8601}.csv",
      type: "text/csv"
  end

  # GET /inventory/pdf — printable snapshot of the current inventory across
  # Shopify and Square, with generated/last-sync timestamps and summary totals.
  # The rendered PDF is cached behind the DataCache version (bumped on every
  # sync / inventory approval), so repeat downloads are instant and the file
  # is regenerated automatically when the mirrored data changes.
  def pdf
    pdf = DataCache.fetch("inventory/pdf") { InventoryPdf.build }
    send_data(
      pdf,
      filename: "inventory-#{Time.current.strftime("%Y-%m-%d-%H%M%S")}.pdf",
      type: "application/pdf",
      disposition: "attachment",
    )
  end

  # POST /inventory/fix_negative — zero one negative variation/variant.
  def fix_negative
    source = params[:source].to_s
    id = params[:id].to_s
    return redirect_to(inventory_index_path, alert: "Missing item") if id.blank?

    if source == "square"
      return redirect_to(inventory_index_path, alert: guard_error("square")) unless guard_ok?("square")
    end

    if NegativeInventory.fix!(source: source, id: id)
      redirect_to(inventory_index_path, notice: "Corrected negative #{source} inventory.")
    else
      redirect_to(inventory_index_path, alert: "Could not correct that item — check the logs.")
    end
  end

  # POST /inventory/fix_all_negative — zero every negative level.
  def fix_all_negative
    unless guard_ok?("square")
      return redirect_to(inventory_index_path, alert: "Square fixes skipped: #{guard_error("square")}")
    end

    results = NegativeInventory.fix_all!
    redirect_to(
      inventory_index_path,
      notice: "Corrected #{results[:square]} Square and #{results[:shopify]} Shopify items (#{results[:failed]} failed).",
    )
  end

  private

  # SKUs reused by variants of more than one distinct product. Duplicate SKUs
  # break Shopify↔Square linking, so these rows get highlighted on the page.
  def shared_sku_set
    rows = ShopifyVariant.joins(:product)
      .where.not(sku: [nil, ""])
      .group('"ShopifyVariant"."sku"', '"ShopifyVariant"."productId"')
      .count
    skus = Set.new
    rows.keys.group_by(&:first).each do |sku, pairs|
      skus << sku if pairs.map(&:last).uniq.length > 1
    end
    skus
  end

  def guard_ok?(platform)
    PlatformPushGuard.authorize!(platform, actor: Current.user.email)
    true
  rescue PlatformPushGuard::LockedError => e
    @guard_error = e.message
    false
  end

  def guard_error(platform)
    @guard_error || PlatformPushGuard.locked_message(platform)
  end

  def authorize_read
    authorize(:module, :inventory_read?)
  end

  def authorize_fix
    authorize(:module, :reconcile_write?)
  end

  # sku => display name + product, resolved once per page so the ledger view
  # doesn't run per-row queries. Square names win for item title (they match
  # the mirrored movement), but Shopify adds the product line.
  def movement_names(movements)
    skus = movements.map(&:sku).compact.uniq
    names = {}
    ShopifyVariant.where(sku: skus).includes(:product).find_each do |variant|
      names[variant.sku] ||= { name: variant.title, product: variant.product&.title }
    end
    SquareVariation.where(sku: skus).find_each do |variation|
      names[variation.sku] ||= { name: variation.name, product: nil }
    end
    names
  end

  # Precompute per-variant quantities and the linked Square quantity so the
  # index view doesn't run per-row queries.
  def variant_quantity_map(products)
    size_map = size_family_map
    map = {}
    products.each do |product|
      product.variants.each do |variant|
        link = variant.sku_links.find(&:linked?)
        map[variant.id] = {
          shopify_qty: variant.levels.sum(&:quantity),
          link: link,
          square_qty: link ? link.square_variation&.levels&.sum(&:quantity) : nil,
          size: size_map[variant.sku.to_s.downcase],
        }
      end
    end
    map
  end

  # sku => size-family membership (root grams, derived target, pending change).
  def size_family_map
    map = {}
    SizeFamily.includes(:members, :size_changes).find_each do |family|
      root = family.base_grams&.to_f
      pending = family.size_changes.select { |change| change.status == "pending" }
        .index_by { |change| change.sku.downcase }
      family.members.each do |member|
        map[member.sku.downcase] = {
          family_id: family.id,
          family: family.name,
          grams: member.grams.to_f,
          root: root,
          target: root ? (root / member.grams.to_f).floor : nil,
          pending: pending[member.sku.downcase],
        }
      end
    end
    map
  end
end
