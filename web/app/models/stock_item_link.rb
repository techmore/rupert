# frozen_string_literal: true

# One exact native platform item for a Rupert item at one site. Links are
# explicit identity decisions; they never change a platform SKU or quantity.
class StockItemLink < ApplicationRecord
  include TenantScoped

  belongs_to :stock_item
  belongs_to :stock_site

  validates :platform, inclusion: { in: StockSite::PLATFORMS }
  validates :native_item_id, presence: true, length: { maximum: 255 }
  validates :match_source, inclusion: { in: %w[manual ctrax_website_variant import] }
  validates :linked_by, presence: true
  validates :native_item_id, uniqueness: { scope: %i[tenant_id stock_site_id platform], message: 'is already linked to another Rupert item at this site' }
  validates :platform, uniqueness: { scope: %i[tenant_id stock_item_id stock_site_id], message: 'already has a link for this item at this site' }
  validate :same_workspace
  validate :native_identity_shape

  private

  def same_workspace
    return if stock_item&.tenant_id == tenant_id && stock_site&.tenant_id == tenant_id

    errors.add(:base, 'Item and site must belong to this workspace.')
  end

  def native_identity_shape
    valid = case platform
    when 'shopify' then native_item_id.to_s.match?(%r{\Agid://shopify/ProductVariant/[1-9][0-9]{0,30}\z})
    when 'ctrax' then native_item_id.to_s.match?(/\A[1-9][0-9]{0,18}\z/)
    when 'square' then native_item_id.to_s.match?(/\A[A-Z0-9]{8,64}\z/)
    end
    errors.add(:native_item_id, 'is not a valid native item ID for this platform') unless valid
    errors.add(:base, "Map this site to a #{MasterStock.platform_label(platform)} location first.") if valid && stock_site && stock_site.public_send("#{platform}_location_id").blank?
  end
end
