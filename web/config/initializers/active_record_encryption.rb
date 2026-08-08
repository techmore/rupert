# frozen_string_literal: true

# Active Record encryption keys. In production these come from the droplet
# environment (RAILS_ENCRYPTION_*_KEY); development/test use fixed keys so
# encrypted settings work out of the box locally.
Rails.application.config.active_record.encryption.primary_key =
  ENV.fetch("RAILS_ENCRYPTION_PRIMARY_KEY", "dev-primary-key-0123456789abcdef")
Rails.application.config.active_record.encryption.deterministic_key =
  ENV.fetch("RAILS_ENCRYPTION_DETERMINISTIC_KEY", "dev-deterministic-key-0123456789")
Rails.application.config.active_record.encryption.key_derivation_salt =
  ENV.fetch("RAILS_ENCRYPTION_KEY_DERIVATION_SALT", "dev-kdf-salt-0123456789abcdef")
