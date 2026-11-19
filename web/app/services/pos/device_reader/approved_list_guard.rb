# frozen_string_literal: true

module Pos
  module DeviceReader
    # A Payments::ItemEligibility rule. The phone card reader cannot have a
    # processor-approved product list yet (the list table does not accept this
    # processor), so it must not become the unrestricted way to charge an item
    # another processor refused. Until it has its own list, a workspace that
    # enforces an approved list for any card processor cannot charge on the
    # phone card reader at all. Other processors are never affected.
    class ApprovedListGuard
      REASON = 'the phone card reader has no approved product list yet'

      def call(processor:, item:)
        return nil unless processor == PROVIDER

        @restricted = ProcessorCatalog.where(enforced: true).exists? if @restricted.nil?
        @restricted ? REASON : nil
      end
    end
  end
end
