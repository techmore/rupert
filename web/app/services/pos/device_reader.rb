# frozen_string_literal: true

module Pos
  # Card payments where the phone, not the server, talks to the card reader.
  #
  # The phone app runs the reader through a payment provider's native SDK and
  # tells Rupert what happened. Rupert's server is the system of record: it
  # fixes the amount and reference before the reader runs, treats the phone's
  # report as a hint, and marks a sale paid only after its own lookup with the
  # provider (Pos::DeviceReaderPayment). Card data stays in the reader.
  #
  # A gateway is one provider's server-side half. It answers:
  #
  #   new(setting)                  the store's PosSetting; raises Pos::Error if unusable
  #   version                       the setting's lock_version when the gateway was built
  #   assert_checkout!(checkout)    raises unless the checkout belongs to this exact setup
  #   verify!                       proves the saved identifiers without running a card
  #   reader_params                 non-secret values the phone needs to run the reader
  #   lookup(reference)             => Result for our reference (read-only)
  #   void(reference:, amount_cents:)                       => Result
  #   refund(reference:, original_reference:, amount_cents:) => Result
  #
  # The only gateway today is FakeGateway (tests and development). One future
  # implementation is Dejavoo's phone SDK with its status lookup; it would be a
  # second class here, chosen in gateway_class. Until one exists, production
  # has no gateway and the feature cannot be used there.
  #
  # See docs/integrations/device-reader-payments.md.
  module DeviceReader
    PROVIDER = 'device_reader'
    CURRENCY = 'USD'
    REFERENCE = /\A[A-Za-z0-9]{1,50}\z/
    PROCESSOR_REFERENCE = /\A[A-Za-z0-9-]{1,40}\z/
    AUTH_CODE = /\A[A-Za-z0-9]{1,12}\z/
    LAST_FOUR = /\A\d{4}\z/
    CARD_BRANDS = %w[Visa Mastercard Amex Discover JCB].freeze
    ENTRY_METHODS = %w[contactless chip swipe manual].freeze

    # Everything Rupert keeps from a provider answer. "approved" and "partial"
    # mean a card was charged; "declined" and "cancelled" mean it was not;
    # "not_found" means the provider has no record of the reference (yet);
    # anything else is "unknown" and must be looked up again, never retried.
    Result = Data.define(:outcome, :reference_id, :kind, :currency, :total_cents, :tip_cents, :fee_cents, :processor_reference,
      :auth_code, :card_brand, :card_last_four, :entry_method, :voided, :settled) do
      def approved? = outcome == 'approved'
      def charged? = %w[approved partial].include?(outcome)
      def no_charge? = %w[declined cancelled].include?(outcome)
    end

    module_function

    # nil in production: no real provider is implemented yet.
    def gateway_class = Rails.env.production? ? nil : FakeGateway

    # The deployment allows it and a gateway exists. Lookups, voids and refunds
    # of payments already taken need only this.
    def available? = Rails.application.config.x.device_reader_enabled == true && !gateway_class.nil?

    # New payments also need the workspace's own flag (absent = off).
    def enabled? = available? && FeatureFlag.enabled?(:device_reader)

    def gateway(setting)
      raise Error, 'Phone card reader payments are not available here.' unless available?

      gateway_class.new(setting)
    end

    def reference = "RR#{SecureRandom.hex(12)}"
  end
end
