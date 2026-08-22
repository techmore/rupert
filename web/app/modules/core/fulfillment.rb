# frozen_string_literal: true

module Core
  # A shipment / fulfillment against an order, with carrier tracking. Fed from
  # Shopify fulfillments on sync, or created manually in the office.
  class Fulfillment < ApplicationRecord
    include TenantScoped

    belongs_to :order, class_name: 'Core::Order', inverse_of: :fulfillments

    validates :source, presence: true
    validates :tracking_number, presence: true, if: -> { tracking_company.present? }
    validates :source_fulfillment_id, uniqueness: { scope: :source }, allow_nil: true

    scope :with_tracking, -> { where.not(tracking_number: [nil, '']) }
    scope :recent, ->(limit = 50) { order(created_at: :desc).limit(limit) }

    def tracking?
      tracking_number.present?
    end

    def tracking_url
      super.presence || carrier_tracking_url
    end

    def status_label
      case status
      when 'fulfilled' then 'Fulfilled'
      when 'in_transit' then 'In transit'
      when 'delivered' then 'Delivered'
      else 'Pending'
      end
    end

    private

    # Best-effort deep link when no URL came from the carrier.
    def carrier_tracking_url
      return if tracking_number.blank?

      case tracking_company.to_s.downcase
      when /ups/ then "https://www.ups.com/track?tracknum=#{tracking_number}"
      when /fedex/ then "https://www.fedex.com/fedextrack/?trknbr=#{tracking_number}"
      when /usps/ then "https://tools.usps.com/go/TrackConfirmAction?tLabels=#{tracking_number}"
      when /dhl/ then "https://www.dhl.com/en/express/tracking.html?AWB=#{tracking_number}"
      end
    end
  end
end
