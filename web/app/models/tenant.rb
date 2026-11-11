# frozen_string_literal: true

class Tenant < ApplicationRecord
  self.table_name = 'tenants'
  self.primary_key = 'id'

  has_many :users, dependent: :destroy
  has_many :settings, dependent: :destroy
  has_many :api_access_tokens, dependent: :destroy

  before_create :generate_id

  validates :name, presence: true
  validates :subdomain, length: { maximum: 63 }
  validates :name, length: { maximum: 160 }
  validates :subdomain,
    presence: true,
    uniqueness: true,
    format: { with: /\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/,
              message: 'must be lowercase letters, numbers, and hyphens' }
  validates :shopify_shop_domain,
    allow_blank: true,
    format: { with: /\A[a-z0-9-]+\.myshopify\.com\z/, message: 'must look like your-store.myshopify.com' }

  # Zones a workspace can choose at Settings → Time rules: the United States first, then the rest.
  TIME_ZONES = (ActiveSupport::TimeZone.us_zones + (ActiveSupport::TimeZone.all - ActiveSupport::TimeZone.us_zones)).uniq { |zone| zone.tzinfo.name }.freeze
  # Blank means the instance default (config.time_zone); BusinessClock reads this for every day boundary.
  validates :time_zone, inclusion: { in: ->(_) { TZInfo::Timezone.all_identifiers }, message: 'is not a known time zone' }, allow_blank: true
  normalizes :time_zone, with: ->(value) { value.to_s.strip.presence }

  def to_param
    subdomain
  end

  private

  def generate_id
    self.id ||= SecureRandom.uuid
  end
end
