# frozen_string_literal: true

module Pos
  # Closes the Dejavoo terminal's open batch (SPIn Settle) and compares each
  # closed batch's totals with what Rupert recorded for that batch number:
  # terminal sales Rupert was paid for, minus refunds it sent. Read-only for
  # Rupert's books; a difference names the batch for a person to review (for
  # example a sale run on the terminal outside Rupert).
  class DejavooBatchClose
    Result = Data.define(:batch_number, :count, :dejavoo_sale_cents, :dejavoo_return_cents, :dejavoo_total_cents, :rupert_sale_cents, :rupert_return_cents) do
      def rupert_total_cents = rupert_sale_cents - rupert_return_cents
      def balanced? = !dejavoo_total_cents.nil? && dejavoo_total_cents == rupert_total_cents

      def summary
        money = ->(cents) { cents.nil? ? 'unknown' : format('%.2f', cents / 100.0) }
        base = "Batch #{batch_number || '?'} closed: Dejavoo #{money.call(dejavoo_total_cents)} USD over #{count || '?'} transactions, Rupert #{money.call(rupert_total_cents)} USD."
        balanced? ? "#{base} They match." : "#{base} They differ; check the terminal batch report for sales or refunds made outside Rupert."
      end
    end

    def self.call(setting) = new(setting).call

    def initialize(setting)
      @setting = setting
      @gateway = DejavooSpinGateway.new(setting)
    end

    def call
      @gateway.settle.map do |row|
        number = row[:batch_number]
        attempts = PosPaymentAttempt.joins(:pos_checkout).where(status: 'paid', batch_number: number)
          .where(pos_checkouts: { location_id: @setting.location_id, gateway_provider: 'dejavoo_spin', environment: @setting.environment })
        refunds = PosCardReversal.joins(:pos_checkout).where(status: 'succeeded', kind: 'refund', batch_number: number)
          .where(pos_checkouts: { location_id: @setting.location_id, gateway_provider: 'dejavoo_spin', environment: @setting.environment })
        # A voided sale leaves the batch, so it counts on neither side.
        voided = PosCardReversal.where(status: 'succeeded', kind: 'void', pos_payment_attempt_id: attempts.select(:id)).pluck(:pos_payment_attempt_id)
        sales = number ? attempts.where.not(id: voided).sum('pos_checkouts.total_cents') : 0
        Result.new(batch_number: number, count: row[:count], dejavoo_sale_cents: row[:sale_cents], dejavoo_return_cents: row[:return_cents],
          dejavoo_total_cents: row[:total_cents], rupert_sale_cents: sales, rupert_return_cents: number ? refunds.sum(:amount_cents) : 0)
      end
    end
  end
end
