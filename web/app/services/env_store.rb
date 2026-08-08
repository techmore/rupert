# frozen_string_literal: true

# Reads configuration with DB settings overriding the process environment.
# Settings are editable from the GUI/API (Settings page) so credentials and
# knobs can be imported/exported as .env text without a redeploy.
module EnvStore
  # Keys that the GUI may manage. Boot-time keys (SHOPIFY_API_KEY, SECRET,
  # RAILS_MASTER_KEY, DATABASE_URL...) are set by the droplet env instead.
  MANAGED_KEYS = %w[
    SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SHOPIFY_SHOP_DOMAIN
    SQUARE_APPLICATION_ID SQUARE_ACCESS_TOKEN SQUARE_ENVIRONMENT SQUARE_LOCATION_ID
    SQUARE_SANDBOX_APPLICATION_ID SQUARE_SANDBOX_ACCESS_TOKEN
    SYNC_MINUTES
  ].freeze

  def self.fetch(key, default = nil)
    Setting.find_by(key: key)&.value.presence || ENV.fetch(key, default)
  end

  def self.value(key)
    Setting.find_by(key: key)&.value
  end

  def self.import!(text)
    parsed = parse(text)
    parsed.each do |key, value|
      next unless MANAGED_KEYS.include?(key)

      setting = Setting.find_or_initialize_by(key: key)
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
    Setting.all.to_h { |setting| [setting.key, setting.value] }
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
