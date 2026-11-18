# frozen_string_literal: true

# A sandbox store set up for phone card reader payments, with the workspace
# flag on and the in-memory fake provider (Pos::DeviceReader::FakeGateway)
# reset. No network and no real identifiers: the values below are made up.
#
#   prepare_device_reader_fixture            # @location, @setting, @register, @display, @checkout
#   tap(:approved)                           # the phone's reader finishes; returns the report it would send
module DeviceReaderFixture
  # Made-up install identifiers (the app sends a UUID).
  DEVICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  OTHER_DEVICE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'

  def device_reader_credentials = { merchant_id: 'FIXTURE-MERCHANT', reader_profile_id: 'FIXTURE-PROFILE' }.to_json

  def prepare_device_reader_fixture(user: users(:regular_user), name: 'reader')
    Pos::DeviceReader::FakeGateway.reset!
    FeatureFlag.set(:device_reader, true)
    @user = user
    @location = Location.create!(source: 'ctrax', externalId: "device-#{name}/1", name: "Device #{name} store")
    @display = PosDisplaySession.create!(user: @user, location: @location)
    @register = Sales::PosSession.create!(location: @location, user: @user, name: 'Sandbox', opened_at: Time.current)
    @setting = PosSetting.create!(location: @location, gateway_provider: 'device_reader', environment: 'sandbox', credentials_json: device_reader_credentials)
    @setting.update!(verified_at: Time.current)
    @setting.update!(card_enabled: true)
    @checkout = device_reader_checkout
  end

  def device_reader_checkout(display: @display, user: @user)
    PosCheckout.create!(location: @location, user: user, pos_display_session: display, pos_session: @register,
      cart_revision: 1, reference: SecureRandom.hex(16), tender: 'card', gateway_provider: 'device_reader',
      gateway_fingerprint: @setting.payment_fingerprint, environment: 'sandbox',
      lines_json: [{ 'variant_id' => '7', 'sku' => 'FIX-1', 'category' => 'Fixture', 'title' => 'Fixture tea', 'quantity' => 1, 'unit_price' => '10.05', 'line_total' => '10.05' }],
      subtotal_cents: 1005, tax_cents: 60, tip_cents: 101, total_cents: 1166)
  end

  # The reader finishes for this attempt. Returns the report the phone would send (nil for :timeout).
  def tap(scenario = :approved, attempt: self.attempt)
    Pos::DeviceReader::FakeGateway.present_card(reference: attempt.invoice, amount_cents: 1166, tip_cents: 101, scenario: scenario)
  end

  def attempt = @checkout.pos_payment_attempts.order(:id).last

  def provider_lookups = Pos::DeviceReader::FakeGateway.lookups

  def audit_actions = ActivityLog.where(tenant_id: Current.tenant_id).order(:id).pluck(:action)
end
