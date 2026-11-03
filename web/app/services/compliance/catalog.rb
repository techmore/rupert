# frozen_string_literal: true

module Compliance
  # Reading the approved catalog for a store (F70): the names the register
  # shows, what a locked register may sell, and a read-only drift check against
  # the store's C-Trax snapshot. Nothing here writes to a source platform.
  module Catalog
    module_function

    # variant id => receipt label, for a locked store; {} when unlocked.
    def register_names(location)
      return {} unless location && CompliancePolicy.for(location).locked_catalog

      approved_items(location).to_h { |item| [item.source_variant_id, item.receipt_label] }
    end

    def approved_items(location)
      ComplianceCatalogItem.approved.includes(:compliance_category, :certificates_of_analysis)
        .where(location_id: location.id, source: 'ctrax')
    end

    # Per-variant facts a tile or cart line shows on a locked register.
    def register_badges(location, policy: CompliancePolicy.for(location), on: Date.current)
      approved_items(location).to_h do |item|
        card = item.card_eligible && item.compliance_category.card_eligible && !item.compliance_category.prohibited
        coa = item.current_coa(on: on, max_age_days: policy.coa_max_age_days)
        [item.source_variant_id, { name: item.receipt_label, card: card, coa: coa.present? || !item.coa_required, coa_url: coa&.document_url,
                                   prohibited: item.compliance_category.prohibited }]
      end
    end

    Drift = Data.define(:item, :kind, :message)

    # Approved items whose source variant moved away from what the owner approved:
    # gone from the store, price changed, or renamed at the source. Read-only.
    def drift(location, snapshot: CtraxStockSnapshot.find_by(location: location))
      return [] unless snapshot

      records = snapshot.records.index_by { |row| row['id'].to_s }
      ComplianceCatalogItem.includes(:compliance_category).where(location_id: location.id, source: 'ctrax').ordered.flat_map do |item|
        record = records[item.source_variant_id]
        next [Drift.new(item: item, kind: :missing, message: 'No longer in the store’s C-Trax catalog.')] unless record

        found = []
        if item.approved_price_cents && record['price_cents'] != item.approved_price_cents
          found << Drift.new(item: item, kind: :price, message: "C-Trax price #{money(record['price_cents'])} differs from the approved #{money(item.approved_price_cents)}.")
        end
        if item.source_name.present? && record['name'].to_s != item.source_name
          found << Drift.new(item: item, kind: :renamed, message: "Renamed in C-Trax to “#{record['name']}”.")
        end
        found << Drift.new(item: item, kind: :unlisted, message: 'Hidden (not listed) in C-Trax.') if record['listed'] == false
        found
      end
    end

    def money(cents) = cents.is_a?(Integer) ? format('$%.2f', cents / 100.0) : 'no price'
  end
end
