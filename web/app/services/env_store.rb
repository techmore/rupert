# frozen_string_literal: true

# Reads configuration with DB settings overriding the process environment.
# Settings are editable from the GUI/API (Settings page) so credentials and
# knobs can be imported/exported as .env text without a redeploy.
module EnvStore
  # Keys that the GUI may manage. Boot-time keys (SHOPIFY_API_KEY, SECRET,
  # RAILS_MASTER_KEY, DATABASE_URL...) are set by the droplet env instead.
  MANAGED_KEYS = [
    "SHOPIFY_CLIENT_ID",
    "SHOPIFY_CLIENT_SECRET",
    "SHOPIFY_SHOP_DOMAIN",
    "SQUARE_APPLICATION_ID",
    "SQUARE_ACCESS_TOKEN",
    "SQUARE_ENVIRONMENT",
    "SQUARE_LOCATION_ID",
    "SQUARE_SANDBOX_APPLICATION_ID",
    "SQUARE_SANDBOX_ACCESS_TOKEN",
    "SYNC_MINUTES",
    "GOOGLE_DRIVE_CLIENT_ID",
    "GOOGLE_DRIVE_CLIENT_SECRET",
    "GOOGLE_DRIVE_REFRESH_TOKEN",
    "GOOGLE_DRIVE_FOLDER_ID",
    "GOOGLE_DRIVE_RETENTION",
    "BUZZ_RELAY_URL",
    "BUZZ_PRIVATE_KEY",
    "BUZZ_CHANNEL",
    "OPCODE_BUZZ_PRIVATE_KEY",
  ].freeze

  # Settings (DB) win over ENV. ENV is only consulted as a global fallback
  # when no tenant is in context (platform/setup), so tenant credentials never
  # bleed across tenants.
  def self.fetch(key, default = nil)
    setting = scoped(key)
    return setting.value if setting
    return ENV.fetch(key, default) if Current.tenant_id.nil?

    default
  end

  def self.value(key)
    scoped(key)&.value
  end

  def self.scoped(key)
    Setting.find_by(key: key, tenant_id: Current.tenant_id)
  end

  # Write a managed key into the tenant settings (nil removes it).
  def self.set(key, value)
    raise ArgumentError, "Key is not managed by the settings store" unless MANAGED_KEYS.include?(key)

    if value.nil?
      scoped(key)&.destroy
    else
      setting = Setting.find_or_initialize_by(key: key, tenant_id: Current.tenant_id)
      setting.value = value.to_s
      setting.save!
    end
    value
  end

  def self.import!(text)
    parsed = parse(text)
    parsed.each do |key, value|
      next unless MANAGED_KEYS.include?(key)

      setting = Setting.find_or_initialize_by(key: key, tenant_id: Current.tenant_id)
      setting.value = value
      setting.save!
    end
    parsed.keys & MANAGED_KEYS
  end

  def self.export
    managed = MANAGED_KEYS.to_h { |key| [key, effective(key)] }
    managed
  end

  def self.effective(key)
    fetch(key, "")
  end

  def self.settings_map
    Setting.where(tenant_id: Current.tenant_id).to_h { |setting| [setting.key, setting.value] }
  end

  def self.mask(value)
    return "" if value.blank?

    if value.length <= 8
      "••••••••"
    else
      "#{value[0, 4]}••••#{value[-4, 4]}"
    end
  end

  def self.parse(text)
    text.to_s.lines.each_with_object({}) do |line, result|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      key, _, value = stripped.partition("=")
      key = key.strip
      next if key.empty?

      value = value.strip
      value = value[1..-2] if value.start_with?("\"") && value.end_with?("\"")
      value = value[1..-2] if value.start_with?("'") && value.end_with?("'")
      result[key] = value
    end
  end
end
