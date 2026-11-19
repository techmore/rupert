# frozen_string_literal: true

require 'test_helper'
require_relative '../support/sim_register'

# The made-up register the iPhone simulator tests ring a sale on (test/support/sim_register.rb).
# It must stay a register that checkout accepts, and must never load outside development.
class SimRegisterTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = Tenant.create!(name: 'Juniper & Pine Market', subdomain: SimRegister::SUBDOMAIN)
    Current.tenant = @tenant
    @owner = User.create!(email: SimRegister::OWNER_EMAIL, password: 'fixture-password-1', role: 'admin', tenant: @tenant)
  end
  teardown { Current.reset }

  test 'it refuses to install outside development' do
    error = assert_raises(RuntimeError) { SimRegister.install! }
    assert_match(/development server only/, error.message)
    assert_not Location.exists?(externalId: 'sim/1')
  end

  test 'seeding twice leaves one store, one open register and stock that checkout can price with tax' do
    2.times { SimRegister.seed! }
    Current.tenant = @tenant
    store = Location.find_by!(source: 'ctrax', externalId: 'sim/1')
    assert_equal 1, Sales::PosSession.where(location: store, status: 'open').count
    assert PosSetting.find_by!(location: store).cash_enabled
    assert_not PosSetting.find_by!(location: store).card_enabled
    assert PosConnection.find_by!(provider: 'ctrax').vendor_approved
    snapshot = CtraxStockSnapshot.find_by!(location: store)
    quote = { lines: [{ variant_id: '1', quantity: 1, unit_price: '18.0' }], subtotal: '18.0' }
    Pos::Quote.decorate!(quote, snapshot)
    assert quote[:tax_verified]
    assert_equal 108, quote[:tax_cents]
    assert_equal 1908, quote[:total_before_tip_cents]
  end
end
