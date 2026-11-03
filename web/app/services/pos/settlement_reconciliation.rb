# frozen_string_literal: true

module Pos
  # Read-only comparison of a gateway's settled batches with Rupert's card
  # sales and refunds for one store (F69). Nothing is written to the gateway
  # or to Rupert's books; every exception names the transaction to review.
  #
  # Statuses per row:
  #   matched            gateway and Rupert agree on the transaction and amount
  #   amount_mismatch    same transaction, different amount
  #   not_from_rupert    settled at the gateway, no Rupert checkout (a standalone
  #                      terminal on the same account, virtual terminal, web store)
  #   awaiting_settlement Rupert paid, gateway has it but has not settled it yet
  #   reversed_at_gateway Rupert paid, gateway shows it voided/refunded without a Rupert record
  #   missing_at_gateway Rupert paid, gateway has no settled or pending record
  class SettlementReconciliation
    MAX_DAYS = 31
    MAX_ROWS = 2_000
    MAX_LOOKUPS = 200

    Row = Struct.new(:status, :kind, :transaction_id, :reference, :batch_id, :rupert_cents, :gateway_cents, :checkout_id, keyword_init: true)
    Batch = Struct.new(:id, :settled_at, :charge_cents, :refund_cents, :count, keyword_init: true)
    Report = Struct.new(:from, :to, :processor, :batches, :rows, :terminal_cents, keyword_init: true) do
      def exceptions = rows.reject { |row| row.status == 'matched' }
      def count(status) = rows.count { |row| row.status == status }
      def sum(status, field = :gateway_cents) = rows.select { |row| row.status == status }.sum { |row| row.public_send(field).to_i }
      def balanced? = exceptions.none? { |row| %w[amount_mismatch reversed_at_gateway missing_at_gateway].include?(row.status) }
    end

    def self.call(setting:, from:, to:) = new(setting, from: from, to: to).call

    def initialize(setting, from:, to:)
      raise Error, 'Gateway belongs to another workspace.' unless setting.tenant_id == Current.tenant_id
      raise Error, "Choose a window of at most #{MAX_DAYS} days." unless from < to && to - from <= MAX_DAYS.days
      raise Error, 'For Dejavoo terminals use Close terminal batch in checkout setup: it closes the batch and compares it with Rupert.' if setting.gateway_provider == 'dejavoo_spin'

      @setting = setting
      @from = from
      @to = to
    end

    def call
      rows = []
      batches = []
      gateway_rows = @setting.gateway_provider == 'nmi' ? nmi_rows(batches) : authorize_net_rows(batches)
      matched_charges = Set.new
      matched_refunds = Set.new
      gateway_rows.each do |g|
        if g[:kind] == 'refund'
          reversal = reversals[g[:transaction_id]]
          matched_refunds << reversal.id if reversal
          rows << row_for(g, reversal&.amount_cents, reversal&.pos_checkout_id, reversal&.reference)
        else
          attempt = attempts[g[:transaction_id]]
          matched_charges << attempt.id if attempt
          rows << row_for(g, attempt&.pos_checkout&.total_cents, attempt&.pos_checkout_id, attempt&.invoice)
        end
      end
      rows.concat(unsettled_rupert_rows(matched_charges))
      Report.new(from: @from, to: @to, processor: @setting.gateway_provider, batches: batches, rows: rows,
        terminal_cents: terminal_sales_cents)
    end

    private

    def row_for(gateway_row, rupert_cents, checkout_id, reference)
      status = if rupert_cents.nil? then 'not_from_rupert'
      elsif rupert_cents == gateway_row[:cents] then 'matched'
      else 'amount_mismatch'
      end
      Row.new(status: status, kind: gateway_row[:kind], transaction_id: gateway_row[:transaction_id], reference: reference || gateway_row[:reference],
        batch_id: gateway_row[:batch_id], rupert_cents: rupert_cents, gateway_cents: gateway_row[:cents], checkout_id: checkout_id)
    end

    def checkouts
      PosCheckout.where(location_id: @setting.location_id, tender: 'card', gateway_provider: @setting.gateway_provider,
        gateway_id: @setting.gateway_id, environment: @setting.environment)
    end

    # Paid gateway attempts for this store and account, by transaction id.
    def attempts
      @attempts ||= PosPaymentAttempt.includes(:pos_checkout).where(pos_checkout_id: checkouts.select(:id), status: 'paid')
        .where.not(transaction_id: nil).index_by(&:transaction_id)
    end

    def reversals
      @reversals ||= PosCardReversal.where(pos_checkout_id: checkouts.select(:id), status: 'succeeded', kind: 'refund')
        .where.not(transaction_id: nil).index_by(&:transaction_id)
    end

    # Standalone-terminal card sales recorded in Rupert for the window, to set
    # against "not from Rupert" gateway charges when the terminal shares the account.
    def terminal_sales_cents
      PosCheckout.where(location_id: @setting.location_id, tender: PosCheckout::TERMINAL_CARD, status: 'paid', demo: false, paid_at: @from...@to).sum(:total_cents)
    end

    # Rupert payments in the window that no settled batch accounted for.
    def unsettled_rupert_rows(matched)
      pending = attempts.values.reject { |a| matched.include?(a.id) }.select { |a| a.pos_checkout.paid_at && a.pos_checkout.paid_at >= @from && a.pos_checkout.paid_at < @to }
      raise Error, 'Too many unsettled payments to check at once. Use a smaller window.' if pending.size > MAX_LOOKUPS

      pending.map do |attempt|
        status = gateway_status(attempt)
        voided_here = PosCardReversal.succeeded.where(pos_payment_attempt: attempt, kind: 'void').exists?
        row_status = case status
        when :pending then 'awaiting_settlement'
        when :settled then 'matched' # settled in a batch outside this window
        when :reversed then voided_here ? 'matched' : 'reversed_at_gateway'
        else 'missing_at_gateway'
        end
        Row.new(status: row_status, kind: voided_here ? 'void' : 'charge', transaction_id: attempt.transaction_id, reference: attempt.invoice,
          rupert_cents: attempt.pos_checkout.total_cents, gateway_cents: status == :missing ? nil : attempt.pos_checkout.total_cents, checkout_id: attempt.pos_checkout_id)
      end
    end

    def gateway_status(attempt)
      if @setting.gateway_provider == 'nmi'
        row = nmi.transaction_by_id(attempt.transaction_id)
        return :missing unless row
        return :reversed if row['condition'] == 'canceled'

        row['condition'] == 'complete' ? :settled : :pending
      else
        detail = anet.detail(attempt.transaction_id)
        case detail['transactionStatus']
        when 'capturedPendingSettlement' then :pending
        when 'settledSuccessfully' then :settled
        when 'voided', 'refundSettledSuccessfully', 'refundPendingSettlement' then :reversed
        else :missing
        end
      end
    rescue Error
      :missing
    end

    def anet = @anet ||= Gateway.new(@setting).tap(&:merchant)

    def nmi = @nmi ||= NmiGateway.new(@setting).tap(&:merchant)

    def authorize_net_rows(batches)
      rows = []
      anet.settled_batches(from: @from, to: @to).each do |batch|
        stats = Array(batch['statistics'])
        batches << Batch.new(id: batch['batchId'].to_s, settled_at: batch['settlementTimeUTC'],
          charge_cents: stats.sum { |s| cents(s['chargeAmount']) }, refund_cents: stats.sum { |s| cents(s['refundAmount']) },
          count: stats.sum { |s| s['chargeCount'].to_i + s['refundCount'].to_i })
        anet.batch_transactions(batch['batchId']).each do |t|
          kind = case t['transactionStatus']
          when 'settledSuccessfully' then 'charge'
          when 'refundSettledSuccessfully' then 'refund'
          end
          next unless kind

          rows << { kind: kind, transaction_id: t['transId'].to_s, reference: t['invoiceNumber'], batch_id: batch['batchId'].to_s, cents: cents(t['settleAmount']) }
          raise Error, 'Too many settled transactions. Use a smaller window.' if rows.size > MAX_ROWS
        end
      end
      rows
    end

    def nmi_rows(batches)
      rows = []
      totals = Hash.new { |h, k| h[k] = { charge: 0, refund: 0, count: 0, at: nil } }
      nmi.settled(from: @from, to: @to).each do |t|
        settle = t['actions'].select { |a| a['action_type'] == 'settle' && a['success'] == '1' }
        next if settle.empty?

        refund = t['actions'].any? { |a| %w[refund credit].include?(a['action_type']) } && t['actions'].none? { |a| a['action_type'] == 'sale' }
        batch_id = settle.last['batch_id'].to_s
        amount = cents(settle.last['amount']).abs
        totals[batch_id][refund ? :refund : :charge] += amount
        totals[batch_id][:count] += 1
        totals[batch_id][:at] ||= settle.last['date']
        rows << { kind: refund ? 'refund' : 'charge', transaction_id: t['transaction_id'], reference: t['order_id'], batch_id: batch_id, cents: amount }
        raise Error, 'Too many settled transactions. Use a smaller window.' if rows.size > MAX_ROWS
      end
      totals.each { |id, t| batches << Batch.new(id: id, settled_at: t[:at], charge_cents: t[:charge], refund_cents: t[:refund], count: t[:count]) }
      rows
    end

    def cents(value)
      return 0 if value.nil?
      raise Error, 'A settled amount could not be read.' unless value.to_s.match?(/\A-?\d{1,9}(?:\.\d{1,4})?\z/)

      (BigDecimal(value.to_s) * 100).round.to_i
    end
  end
end
