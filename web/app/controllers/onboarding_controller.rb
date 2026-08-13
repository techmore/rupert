# frozen_string_literal: true

# Onboarding checklist: guides the admin through connecting Shopify + Square
# before the ERP becomes useful. Once the required keys are set it redirects to
# the dashboard.
class OnboardingController < ApplicationController
  REQUIRED_KEYS = ["SHOPIFY_CLIENT_ID", "SHOPIFY_CLIENT_SECRET"].freeze
  OPTIONAL_KEYS = ["SQUARE_ACCESS_TOKEN"].freeze

  def self.configured?
    REQUIRED_KEYS.all? { |key| EnvStore.fetch(key, "").present? }
  end

  def index
    return redirect_to(root_path) if self.class.configured?

    @status = EnvStore.export.each_with_object({}) do |(key, value), out|
      out[key] = value.present?
    end
    @required = REQUIRED_KEYS.index_with { |k| @status[k] }
    @optional = OPTIONAL_KEYS.index_with { |k| @status[k] }
  end
end
