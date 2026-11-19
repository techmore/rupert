# frozen_string_literal: true

module Pos
  module DeviceReader
    # A pretend payment provider for tests and development. No network, no
    # money, no real card. It refuses to exist in production.
    #
    # It plays both halves of a provider: `present_card` is the phone's reader
    # finishing (it writes the provider's record and returns what the phone
    # would report), and an instance answers the server's lookup, void and
    # refund from that record. The record lives in this process's memory.
    #
    #   report = FakeGateway.present_card(reference: 'RR…', amount_cents: 1166, scenario: :approved)
    #
    # Scenarios: :approved, :declined, :cancelled, :timeout (no record and no
    # report), :wrong_amount (approved with a fee added) and :partial (approved
    # for half). A duplicate report is the same report sent twice; a late result
    # is `present_card` called after the server gave up on the attempt.
    class FakeGateway
      SCENARIOS = %i[approved declined cancelled timeout wrong_amount partial].freeze
      # Public test card details only.
      CARD = { card_brand: 'Visa', card_last_four: '1111', entry_method: 'contactless', auth_code: 'A1B2C3' }.freeze

      @ledger = {}
      @outages = []
      @lookups = 0
      @mutex = Mutex.new

      class << self
        attr_reader :lookups

        def reset!
          @mutex.synchronize do
            @ledger = {}
            @outages = []
            @lookups = 0
          end
        end

        # The reader finished for this reference. Returns the report the phone
        # would send to Rupert (string keys), or nil when it has nothing to say.
        def present_card(reference:, amount_cents:, tip_cents: 0, scenario: :approved)
          raise ArgumentError, "Unknown scenario #{scenario.inspect}" unless SCENARIOS.include?(scenario)
          return nil if scenario == :timeout

          row = { kind: 'sale', voided: false, settled: false, tip_cents: tip_cents, fee_cents: 0, total_cents: amount_cents,
                  processor_reference: "FAKE#{SecureRandom.hex(6).upcase}" }
          case scenario
          when :declined, :cancelled then row.merge!(outcome: scenario.to_s, total_cents: 0, tip_cents: 0)
          when :wrong_amount then row.merge!(outcome: 'approved', total_cents: amount_cents + 35, fee_cents: 35)
          when :partial then row.merge!(outcome: 'partial', total_cents: amount_cents / 2, tip_cents: 0)
          else row[:outcome] = 'approved'
          end
          @mutex.synchronize { @ledger[reference] = row }
          return { 'status' => row[:outcome] } unless %w[approved partial].include?(row[:outcome])

          { 'status' => 'approved', 'provider_reference' => row[:processor_reference], 'amount_cents' => row[:total_cents],
            'card_brand' => CARD[:card_brand], 'last_four' => CARD[:card_last_four], 'entry_method' => CARD[:entry_method],
            'auth_code' => CARD[:auth_code] }
        end

        # The provider closed its batch: the sale can no longer be voided.
        def settle!(reference) = @mutex.synchronize { @ledger.fetch(reference)[:settled] = true }

        # The next call of this kind (:lookup, :void or :refund) gets no answer.
        def fail_next(operation) = @mutex.synchronize { @outages << operation }

        def row(reference) = @mutex.synchronize { @ledger[reference]&.dup }

        def update(reference, row) = @mutex.synchronize { @ledger[reference] = row }

        def outage?(operation)
          @mutex.synchronize do
            @lookups += 1 if operation == :lookup
            index = @outages.index(operation)
            index ? @outages.delete_at(index) : nil
          end
        end
      end

      attr_reader :setting, :version

      def initialize(setting)
        raise Error, 'The fake card reader provider never runs in production.' if Rails.env.production?
        raise Error, 'Gateway belongs to another workspace.' unless setting.persisted? && setting.tenant_id == Current.tenant_id
        raise Error, 'This store is not set up for phone card reader payments.' unless setting.gateway_provider == PROVIDER
        raise Error, 'Phone card reader production needs owner sign-off in checkout setup first.' unless setting.device_reader_ready_environment?
        unless PosSetting::CREDENTIAL_KEYS.fetch(PROVIDER).all? { |key| setting.credentials[key].present? }
          raise Error, 'Save the phone card reader merchant identifiers first.'
        end

        @setting = setting
        @version = setting.lock_version
        @fingerprint = setting.payment_fingerprint
      end

      def assert_checkout!(checkout)
        unless checkout.tenant_id == Current.tenant_id && checkout.location_id == @setting.location_id &&
            checkout.gateway_provider == PROVIDER && checkout.environment == @setting.environment &&
            checkout.gateway_fingerprint == @fingerprint
          raise Error, 'Phone card reader setup changed. Review the original payment setup.'
        end
      end

      def verify! = true

      # A real provider may need a non-secret profile name here. Never a key.
      def reader_params = {}

      def lookup(reference)
        unclear!(:lookup)
        row = self.class.row(checked(reference))
        row ? result(reference, row) : blank('not_found')
      end

      def void(reference:, amount_cents:)
        unclear!(:void)
        row = self.class.row(checked(reference))
        return blank('not_found') unless row
        return blank('declined') if row[:settled] || row[:voided] || !%w[approved partial].include?(row[:outcome]) || row[:total_cents] != amount_cents

        row[:voided] = true
        self.class.update(reference, row)
        result(reference, row)
      end

      def refund(reference:, original_reference:, amount_cents:)
        unclear!(:refund)
        original = self.class.row(checked(original_reference))
        return blank('declined') unless original && original[:outcome] == 'approved' && !original[:voided] && amount_cents.between?(1, original[:total_cents])

        row = { kind: 'refund', outcome: 'approved', voided: false, settled: false, total_cents: amount_cents, tip_cents: 0, fee_cents: 0,
                processor_reference: "FAKE#{SecureRandom.hex(6).upcase}" }
        self.class.update(checked(reference), row)
        result(reference, row)
      end

      private

      def unclear!(operation)
        raise Error, 'The payment provider did not answer. Check payment status before retrying.' if self.class.outage?(operation)
      end

      def checked(reference)
        raise Error, 'Invalid payment reference.' unless reference.to_s.match?(REFERENCE)

        reference.to_s
      end

      def result(reference, row)
        charged = %w[approved partial].include?(row[:outcome])
        Result.new(outcome: row[:outcome], reference_id: reference, kind: row[:kind], currency: CURRENCY, total_cents: row[:total_cents],
          tip_cents: row[:tip_cents], fee_cents: row[:fee_cents], processor_reference: row[:processor_reference],
          auth_code: charged ? CARD[:auth_code] : nil, card_brand: charged ? CARD[:card_brand] : nil,
          card_last_four: charged ? CARD[:card_last_four] : nil, entry_method: charged ? CARD[:entry_method] : nil,
          voided: row[:voided], settled: row[:settled])
      end

      def blank(outcome)
        Result.new(outcome: outcome, reference_id: nil, kind: nil, currency: nil, total_cents: nil, tip_cents: nil, fee_cents: nil,
          processor_reference: nil, auth_code: nil, card_brand: nil, card_last_four: nil, entry_method: nil, voided: false, settled: false)
      end
    end
  end
end
