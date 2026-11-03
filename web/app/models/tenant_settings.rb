# frozen_string_literal: true

# Per-tenant business settings stored as Setting rows. Fallbacks keep the app
# working before any settings are configured.
class TenantSettings
  DEFAULTS = {
    # Blank: business_name falls back to the workspace's own name (below).
    business_name: '',
    invoice_prefix: 'INV',
    low_stock_threshold: 5,
    # Percent used only to estimate tax for sources that do not report it
    # (SwipeSimple). Blank means no estimate is shown.
    sales_tax_rate: '',
    # NAB / IRIS merchant number whose deposits fund SwipeSimple card sales.
    # Chosen by the owner on the SwipeSimple daily close page; never defaulted.
    swipesimple_deposit_merchant: ''
  }.freeze

  class << self
    (DEFAULTS.keys - [:business_name]).each do |key|
      define_method(key) do
        value = Setting.for_tenant("tenant_#{key}")&.value
        value.presence || DEFAULTS[key]
      end
    end

    def set(key, value)
      raise ArgumentError, "unknown setting #{key}" unless DEFAULTS.key?(key.to_sym)

      Setting.find_or_create_for("tenant_#{key}", Current.tenant_id) do |setting|
        setting.value = value.to_s
      end
    end

    # The name printed on invoices and receipts. Until the owner sets one, it is
    # the workspace's name, never another business's.
    def business_name
      Setting.for_tenant('tenant_business_name')&.value.presence || Current.tenant&.name.presence || 'Rupert'
    end

    def low_stock_threshold_int
      low_stock_threshold.to_s.to_i
    end
  end
end
