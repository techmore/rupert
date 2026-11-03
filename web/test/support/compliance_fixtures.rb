# frozen_string_literal: true

# Builders for F70 compliance tests: a C-Trax store with two variants, approved
# categories, catalog items, COAs and managers with override PINs.
module ComplianceFixtures
  def compliance_store(name: 'Compliance store', external_id: "compliance/#{SecureRandom.hex(3)}")
    location = Location.create!(source: 'ctrax', externalId: external_id, name: name)
    CtraxStockSnapshot.create!(location: location, api_origin: 'https://fixture.api.cannatrax.net', store_id: '9', captured_at: Time.current,
      records_json: [
        { 'id' => '11', 'name' => 'Calm Drops 1000mg', 'product_name' => 'Calm Drops 1000mg', 'sku' => 'TINC-1000', 'category' => 'Tinctures',
          'price_cents' => 4000, 'tax_rate_mbp' => 600_000, 'quantity' => '20', 'manage_stock' => true, 'listed' => true },
        { 'id' => '22', 'name' => 'THCA Flower 3.5g', 'product_name' => 'THCA Flower 3.5g', 'sku' => 'FLWR-35', 'category' => 'Flower',
          'price_cents' => 3000, 'tax_rate_mbp' => 600_000, 'quantity' => '20', 'manage_stock' => true, 'listed' => true },
        { 'id' => '33', 'name' => 'Mystery Item', 'product_name' => 'Mystery Item', 'sku' => 'MYST', 'category' => 'Other',
          'price_cents' => 500, 'tax_rate_mbp' => 600_000, 'quantity' => '20', 'manage_stock' => true, 'listed' => true }
      ])
    location
  end

  def card_category = @card_category ||= ComplianceCategory.create!(name: "CBD tinctures #{SecureRandom.hex(2)}", card_eligible: true)
  def cash_category = @cash_category ||= ComplianceCategory.create!(name: "Smokable hemp #{SecureRandom.hex(2)}", card_eligible: false)

  def approve!(location, variant_id, name:, category:, card: true, coa: true, **attrs)
    item = ComplianceCatalogItem.create!(location: location, source_variant_id: variant_id, compliant_name: name, compliance_category: category,
      card_eligible: card, approved_at: Time.current, **attrs)
    add_coa!(item) if coa
    item
  end

  def add_coa!(item, tested_on: 30.days.ago.to_date, **attrs)
    item.certificates_of_analysis.create!(lab_name: 'Fixture Labs', report_identifier: "R-#{item.id}", tested_on: tested_on,
      document_url: "https://labs.example.com/coa/#{item.id}.pdf", **attrs)
  end

  def manager_with_pin(pin: '4321', email: "manager-#{SecureRandom.hex(3)}@example.com")
    user = User.create!(email: email, password: 'password123', role: 'manager', tenant_id: Current.tenant_id, name: 'Morgan Manager')
    user.pos_override_pin = pin
    user.save!
    user
  end

  def cashier(email: "cashier-#{SecureRandom.hex(3)}@example.com")
    User.create!(email: email, password: 'password123', role: 'employee', tenant_id: Current.tenant_id, name: 'Casey Cashier')
  end
end
