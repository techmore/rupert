# frozen_string_literal: true

module Compliance
  # Approving a store's C-Trax variant onto the locked register catalog, editing
  # its compliant name, category and eligibility, and suspending it. Each change
  # writes a compliance audit row with the before and after values.
  class CatalogItemsController < AuthenticatedController
    include ComplianceAccess

    before_action :require_compliance_editor!
    before_action :load_item, only: %i[edit update suspend reinstate]

    def new
      @location = Location.find(params[:location_id])
      record = source_record(@location, params[:variant_id].to_s) || raise(ActiveRecord::RecordNotFound)
      @item = ComplianceCatalogItem.new(location: @location, source: 'ctrax', source_variant_id: record['id'].to_s,
        source_name: record['name'], sku: record['sku'], compliant_name: record['name'].to_s.first(80),
        approved_price_cents: record['price_cents'].is_a?(Integer) && record['price_cents'].positive? ? record['price_cents'] : nil,
        cash_eligible: true, age_restricted: true, coa_required: true)
      @record = record
    end

    def create
      @location = Location.find(params[:location_id])
      @record = source_record(@location, params[:variant_id].to_s) || raise(ActiveRecord::RecordNotFound)
      @item = ComplianceCatalogItem.new(item_params.merge(location: @location, source: 'ctrax', source_variant_id: @record['id'].to_s,
        source_name: @record['name'], sku: @record['sku'], approved_by_id: Current.user.id, approved_at: Time.current))
      saved = ComplianceCatalogItem.transaction do
        next false unless @item.save

        ComplianceEvent.record!('catalog_item_approved', subject: @item, details: { 'after' => @item.audit_snapshot })
        true
      end
      return render(:new, status: :unprocessable_entity) unless saved

      redirect_to compliance_path(location_id: @location.id, q: @item.compliant_name), notice: "#{@item.compliant_name} is on the approved catalog."
    end

    def edit; end

    def update
      before = @item.audit_snapshot
      saved = ComplianceCatalogItem.transaction do
        next false unless @item.update(item_params.merge(approved_by_id: Current.user.id, approved_at: Time.current))

        ComplianceEvent.record!('catalog_item_edited', subject: @item, details: { 'before' => before, 'after' => @item.audit_snapshot })
        true
      end
      return render(:edit, status: :unprocessable_entity) unless saved

      redirect_to compliance_path(location_id: @item.location_id, q: @item.compliant_name), notice: 'Approved item saved.'
    rescue ActiveRecord::StaleObjectError
      redirect_to edit_compliance_catalog_item_path(@item), alert: 'Someone else changed this item. Review it and save again.'
    end

    def suspend = change_status('suspended', 'catalog_item_suspended', 'suspended: it cannot be rung up')
    def reinstate = change_status('approved', 'catalog_item_reinstated', 'back on the approved catalog')

    private

    def load_item
      @item = ComplianceCatalogItem.includes(:compliance_category, :certificates_of_analysis).find(params[:id])
      @location = @item.location
      @record = source_record(@location, @item.source_variant_id)
    end

    def change_status(status, action, words)
      reason = params[:reason].to_s.squish
      return redirect_to(edit_compliance_catalog_item_path(@item), alert: 'Give a reason of at least 8 characters.') if reason.length < 8

      ComplianceCatalogItem.transaction do
        @item.update!(status: status)
        ComplianceEvent.record!(action, subject: @item, reason: reason)
      end
      redirect_to edit_compliance_catalog_item_path(@item), notice: "#{@item.compliant_name} is #{words}."
    end

    def source_record(location, variant_id)
      CtraxStockSnapshot.find_by(location: location)&.records&.find { |row| row['id'].to_s == variant_id }
    end

    def item_params
      permitted = params.require(:compliance_catalog_item).permit(:compliant_name, :receipt_name, :compliance_category_id, :card_eligible,
        :cash_eligible, :age_restricted, :coa_required, :thc_mg_per_container, :approved_price, :lock_version)
      price = permitted.delete(:approved_price).to_s.strip
      permitted[:approved_price_cents] = price.match?(/\A\d{1,6}(?:\.\d{1,2})?\z/) ? (BigDecimal(price) * 100).to_i : nil
      permitted[:thc_mg_per_container] = permitted[:thc_mg_per_container].presence
      if permitted[:compliance_category_id].present? && !ComplianceCategory.exists?(id: permitted[:compliance_category_id])
        permitted[:compliance_category_id] = nil
      end
      permitted
    end
  end
end
