# frozen_string_literal: true

# Deployment switch for phone card reader payments (Pos::DeviceReader).
# Off in production unless RUPERT_DEVICE_READER_ENABLED=1. While off, the
# /native/reader_attempts routes do not exist and the provider cannot be saved.
# A workspace also needs its own flag (FeatureFlag :device_reader, off by
# default, no settings screen), and production has no gateway to use until a
# real provider is added: see docs/integrations/device-reader-payments.md.
Rails.application.config.x.device_reader_enabled =
  ENV.fetch('RUPERT_DEVICE_READER_ENABLED') { Rails.env.production? ? '0' : '1' } == '1'

# Fail closed on approved products: see Pos::DeviceReader::ApprovedListGuard.
Rails.application.config.to_prepare do
  Payments::ItemEligibility.register_rule(Pos::DeviceReader::ApprovedListGuard)
end
