# frozen_string_literal: true

# A Rupert stock site: one physical shop or stockroom, mapped to at most one
# location per platform. Rupert balances are kept per item and site.
class StockSite < ApplicationRecord
  include TenantScoped

  PLATFORMS = %w[shopify ctrax square].freeze

  has_many :balances, class_name: 'StockBalance', dependent: :restrict_with_exception
  has_many :links, class_name: 'StockItemLink', dependent: :restrict_with_exception

  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { scope: :tenant_id }
  validate :platform_locations_match

  scope :active, -> { where(active: true) }

  def platform_location(platform)
    id = public_send("#{platform}_location_id")
    id && Location.find_by(id: id, source: platform)
  end

  def mapped_platforms
    PLATFORMS.select { |platform| public_send("#{platform}_location_id").present? }
  end

  private

  def platform_locations_match
    PLATFORMS.each do |platform|
      id = public_send("#{platform}_location_id")
      next if id.blank?

      location = Location.find_by(id: id)
      unless location && location.tenant_id == tenant_id && location.source == platform
        errors.add(:base, "Choose a #{platform_label(platform)} location from this workspace.")
      end
      if StockSite.where("#{platform}_location_id" => id).where.not(id: self.id).exists?
        errors.add(:base, "That #{platform_label(platform)} location already belongs to another site.")
      end
    end
  end

  def platform_label(platform) = MasterStock.platform_label(platform)
end
