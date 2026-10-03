# frozen_string_literal: true

# Onboarding checklist: guides the admin through connecting Shopify + Square
# before the ERP becomes useful. Once the required keys are set it redirects to
# the dashboard.
class OnboardingController < ApplicationController
  REQUIRED_KEYS = %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET].freeze
  OPTIONAL_KEYS = ['SQUARE_ACCESS_TOKEN'].freeze

  # Fields collectable inline on this page: form param → managed env key.
  CONNECTABLE_KEYS = {
    shopify_client_id: 'SHOPIFY_CLIENT_ID',
    shopify_client_secret: 'SHOPIFY_CLIENT_SECRET',
    shopify_shop_domain: 'SHOPIFY_SHOP_DOMAIN',
    square_access_token: 'SQUARE_ACCESS_TOKEN'
  }.freeze

  def self.configured?
    REQUIRED_KEYS.all? { |key| EnvStore.fetch(key, '').present? }
  end

  def index
    return redirect_to(root_path) if self.class.configured?

    @status = EnvStore.export.each_with_object({}) do |(key, value), out|
      out[key] = value.present?
    end
    @required = REQUIRED_KEYS.index_with { |k| @status[k] }
    @optional = OPTIONAL_KEYS.index_with { |k| @status[k] }
  end

  # POST /onboarding/connect — collect the keys inline so the admin never has
  # to visit Settings and paste a raw .env blob. Each field is optional; only
  # provided values are written. After saving, a first sync kicks off
  # automatically when the required Shopify keys are present.
  def connect
    save_submitted_keys
    return redirect_to(onboarding_path, alert: 'Unknown setting key submitted.') if @invalid.any?

    return first_sync_and_redirect if self.class.configured?

    redirect_to(onboarding_path,
      notice: 'Saved. Add your Shopify client ID and secret to finish connecting.')
  rescue StandardError => e
    redirect_to(onboarding_path, alert: "Could not save credentials: #{e.message}")
  end

  private

  def first_sync_and_redirect
    SyncJob.perform_later(tenant_id: Current.tenant_id, mode: 'manual', actor: Current.user.email)
    redirect_to(root_path,
      notice: 'Accounts connected — first sync is running. This page will fill in as data arrives.')
  end

  def save_submitted_keys
    @invalid = []
    CONNECTABLE_KEYS.each do |param, key|
      value = params[param].to_s.strip
      next if value.blank?

      if EnvStore::MANAGED_KEYS.include?(key)
        EnvStore.set(key, value)
      else
        @invalid << key
      end
    end
  end
end
