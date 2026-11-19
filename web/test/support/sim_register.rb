# frozen_string_literal: true

# A made-up register for the iPhone app's simulator tests and for a person following
# docs/ios/employee-test-script.md. It lives in the fictional App Review workspace
# (rupert:app_review_demo) and gives it what the Rails suite gives its checkout tests
# (test/integration/pos_checkout_test.rb): a store, a stock snapshot with prices, tax rates and
# quantities, cash turned on, an open register, an approved C-Trax connection with fixture
# credentials, and Ctrax::StockSync.call stubbed so no request ever leaves the machine.
#
# It is loaded by test/support/sim_register.ru, never by the app. Development only:
#
#   bin/rails server -c test/support/sim_register.ru -b 127.0.0.1 -p 3005
module SimRegister
  SUBDOMAIN = 'app-review-demo'
  ORIGIN = 'https://fixture.api.cannatrax.net'
  STORE_ID = '1'
  STORE_NAME = 'Test register'
  REGISTER_NAME = 'Front counter'
  OWNER_EMAIL = 'appreview@rupertpos.com'
  IMAGE = 'https://cdn.shopify.com/s/files/sim/placeholder.png'
  # id, name, price in cents. Tax is 6% on every item, as in the checkout tests.
  ITEMS = [['1', 'Cedar Candle', 1800], ['2', 'Pine Soap', 650], ['3', 'Juniper Tea Tin', 1235], ['4', 'Market Tote', 2200]].freeze
  TAX_RATE_MBP = 600_000

  module_function

  def install!
    raise 'The simulator register is for a local development server only.' unless Rails.env.development?

    seed!
    # Code reloading replaces the class, so the stub is put back each time.
    Rails.application.reloader.to_prepare { SimRegister.stub_stock_sync! }
    stub_stock_sync!
  end

  def seed!
    tenant = Tenant.find_by(subdomain: SUBDOMAIN) or raise "Run REVIEW_PASSWORD='…' bin/rails rupert:app_review_demo first."
    Current.set(tenant: tenant) do
      store = Location.find_or_create_by!(source: 'ctrax', externalId: 'sim/1') { |location| location.name = STORE_NAME }
      ITEMS.each do |id, name, _|
        ShopifyProduct.find_or_create_by!(id: "sim-#{id}") do |product|
          product.title = name
          product.status = 'ACTIVE'
          product.featuredImageUrl = IMAGE
        end
      end
      CtraxStockSnapshot.find_or_initialize_by(location: store).update!(api_origin: ORIGIN, store_id: STORE_ID, captured_at: Time.current, records_json: records)
      PosConnection.find_or_create_by!(provider: 'ctrax') do |connection|
        connection.vendor_approved = true
        connection.credentials_json = { api_url: ORIGIN, api_username: 'fixture', api_password: 'private-fixture' }.to_json
      end
      PosSetting.find_or_create_by!(location: store).update!(cash_enabled: true)
      Sales::PosSession.find_by(location: store, name: REGISTER_NAME, status: 'open') ||
        Sales::PosSession.create!(location: store, name: REGISTER_NAME, user: User.find_by!(email: OWNER_EMAIL), opened_at: Time.current)
    end
  end

  def records
    ITEMS.map do |id, name, cents|
      { 'id' => id, 'name' => name, 'product_name' => name, 'category' => 'Gifts', 'sku' => "SIM-#{id}", 'price_cents' => cents,
        'tax_rate_mbp' => TAX_RATE_MBP, 'quantity' => '500', 'manage_stock' => true, 'listed' => true }
    end
  end

  # What the suite does with `Ctrax::StockSync.stubs(:call)`: checkout asks for a fresh stock
  # read before it takes payment, and here that read is the snapshot above, marked current.
  def stub_stock_sync!
    Ctrax::StockSync.define_singleton_method(:call) do |connection:|
      snapshots = CtraxStockSnapshot.where(api_origin: SimRegister::ORIGIN)
      snapshots.update_all(captured_at: Time.current)
      connection.update!(last_check_status: 'verified', last_checked_at: Time.current)
      { stores: snapshots.count, variants: SimRegister::ITEMS.size }
    end
  end
end
