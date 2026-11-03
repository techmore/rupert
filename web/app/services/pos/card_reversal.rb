# frozen_string_literal: true

module Pos
  # Void or refund a gateway card payment taken by Rupert POS (F69).
  #
  # - Void vs refund is chosen from the gateway's own status: an unsettled
  #   charge can only be voided (whole amount); a settled one is refunded
  #   (part or all, up to what is left).
  # - A durable reversal row exists before any gateway call. A lost response
  #   stays `unknown`; a read-only recheck settles it. No blind retries.
  # - Success records a Core::Refund on the sale, so books and reports follow.
  #   Stock is not returned automatically: restock returned goods separately.
  class CardReversal
    ANET_ID = /\A[1-9][0-9]{0,29}\z/

    def self.call(checkout:, amount_cents:, reason:, user:)
      new(checkout).call(amount_cents: amount_cents, reason: reason, user: user)
    end

    def self.reconcile!(reversal)
      new(reversal.pos_checkout).reconcile!(reversal)
    end

    def initialize(checkout)
      raise Error, 'Checkout belongs to another workspace.' unless checkout.tenant_id == Current.tenant_id

      @checkout = checkout
    end

    def call(amount_cents:, reason:, user:)
      amount = amount_cents.to_i
      raise Error, 'Only paid card checkouts charged through Rupert can be refunded here.' unless @checkout.tender == 'card' && @checkout.paid? && !@checkout.demo?
      raise Error, 'Enter a reason of at least 3 characters.' unless reason.to_s.squish.length.between?(3, 500)
      attempt = @checkout.pos_payment_attempts.find_by(status: 'paid')
      raise Error, 'No verified gateway payment is recorded for this checkout.' unless attempt&.transaction_id.to_s.match?(ANET_ID)

      state = gateway_state(attempt)
      reversal = nil
      @checkout.with_lock do
        raise Error, 'A refund for this sale is still being checked. Recheck it before starting another.' if PosCardReversal.unresolved.where(pos_checkout: @checkout).exists?
        refunded = PosCardReversal.succeeded.where(pos_checkout: @checkout).sum(:amount_cents)
        remaining = @checkout.total_cents - refunded
        raise Error, "Enter an amount between 0.01 and #{format('%.2f', remaining / 100.0)}." unless amount.positive? && amount <= remaining

        kind = state.fetch(:settled) ? 'refund' : 'void'
        if kind == 'void' && (amount != @checkout.total_cents || refunded.positive?)
          raise Error, "This card payment hasn't settled yet, so only the whole sale can be voided today. Refund part of it after it settles (usually the next business day)."
        end
        reversal = PosCardReversal.create!(pos_checkout: @checkout, pos_payment_attempt: attempt, kind: kind, amount_cents: amount,
          reference: "RV#{SecureRandom.hex(9)}", reason: reason.to_s.squish, requested_by: user, submitted_at: Time.current)
      end

      # No database lock spans the gateway request.
      result = reversal.kind == 'void' ? submit_void(attempt, reversal) : submit_refund(attempt, reversal, state)
      apply(reversal, result)
      reversal.reload
    rescue Error
      reversal.update!(status: 'unknown') if reversal&.reload&.status == 'submitting'
      raise
    end

    def reconcile!(reversal)
      return reversal unless reversal.unresolved?

      attempt = reversal.pos_payment_attempt
      result = if nmi?
        reconcile_nmi(reversal, attempt)
      else
        reconcile_authorize_net(reversal, attempt)
      end
      apply(reversal, result) if result
      reversal.reload
    end

    private

    def nmi? = @checkout.gateway_provider == 'nmi'

    def setting
      @setting ||= PosSetting.find_by!(location: @checkout.location).tap do |row|
        unless row.gateway_provider == @checkout.gateway_provider && row.gateway_id == @checkout.gateway_id && row.environment == @checkout.environment
          raise Error, 'The store now uses a different gateway account. Refund this sale in the original gateway account.'
        end
      end
    end

    def anet
      @anet ||= Gateway.new(setting).tap(&:merchant)
    end

    def nmi
      @nmi ||= NmiGateway.new(setting).tap { |gateway| gateway.assert_checkout!(@checkout) }.tap(&:merchant)
    end

    # { settled:, last_four: } from the gateway's current record of the charge.
    def gateway_state(attempt)
      if nmi?
        row = nmi.transaction_by_id(attempt.transaction_id)
        raise Error, 'NMI has no record of this payment.' unless row && row['order_id'] == attempt.invoice
        raise Error, 'This payment was voided or refunded outside Rupert. Check the NMI portal.' if reversed_outside_rupert?(row, attempt)

        case row['condition']
        when 'pendingsettlement' then { settled: false }
        when 'complete' then { settled: true }
        else raise Error, "NMI shows this payment as #{row['condition']}; it can't be refunded from Rupert."
        end
      else
        row = anet.detail(attempt.transaction_id)
        raise Error, 'Gateway payment does not match this checkout.' unless row.dig('order', 'invoiceNumber') == attempt.invoice
        last_four = Pos::CardPayment.receipt_fields(row)[:card_last_four] || attempt.card_last_four
        case row['transactionStatus']
        when 'capturedPendingSettlement' then { settled: false, last_four: last_four }
        when 'settledSuccessfully' then { settled: true, last_four: last_four }
        when 'voided' then raise Error, 'This payment was already voided in Authorize.net.'
        else raise Error, "Authorize.net shows this payment as #{row['transactionStatus']}; it can't be refunded from Rupert."
        end
      end
    end

    def submit_void(attempt, reversal)
      if nmi?
        nmi_result(nmi.void(attempt.transaction_id))
      else
        anet_result(anet.void(attempt.transaction_id, reversal.reference))
      end
    end

    def submit_refund(attempt, reversal, state)
      if nmi?
        nmi_result(nmi.refund(attempt.transaction_id, reversal.amount_cents))
      else
        anet_result(anet.refund(attempt.transaction_id, reversal.amount_cents, state[:last_four], reversal.reference))
      end
    end

    # => { status: 'succeeded'|'failed'|'unknown', transaction_id:, message: }
    def anet_result(doc)
      response = doc['transactionResponse']
      return { status: 'unknown' } unless response.is_a?(Hash)

      id = response['transId'].to_s
      code = response['errors'].is_a?(Array) && response['errors'].first.is_a?(Hash) ? response['errors'].first['errorCode'] : nil
      case response['responseCode'].to_s
      when '1' then id.match?(ANET_ID) ? { status: 'succeeded', transaction_id: id } : { status: 'unknown' }
      when '2' then { status: 'failed', message: DeclineReason.authorize_net(code) }
      when '3' then id == '0' ? { status: 'failed', message: refund_failure(code) } : { status: 'unknown' }
      else { status: 'unknown' }
      end
    end

    def nmi_result(doc)
      id = doc['transactionid'].to_s
      case doc['response']
      when '1' then id.match?(ANET_ID) ? { status: 'succeeded', transaction_id: id } : { status: 'unknown' }
      when '2', '3' then id.match?(ANET_ID) && doc['response'] == '3' ? { status: 'unknown' } : { status: 'failed', message: DeclineReason.nmi(doc['response_code']) }
      else { status: 'unknown' }
      end
    end

    # Authorize.net reason 54: the charge doesn't meet refund criteria (e.g. not
    # settled, already fully refunded, or over 180 days old).
    def refund_failure(code)
      code.to_s == '54' ? 'The gateway says this charge can no longer be refunded this way. Check it in the gateway portal.' : 'The gateway refused the refund. Nothing was refunded.'
    end

    def reconcile_authorize_net(reversal, attempt)
      if reversal.kind == 'void'
        row = anet.detail(attempt.transaction_id)
        return { status: 'succeeded', transaction_id: attempt.transaction_id } if row['transactionStatus'] == 'voided'
        return { status: 'failed', message: 'The void did not apply. Nothing was reversed.' } if %w[capturedPendingSettlement settledSuccessfully].include?(row['transactionStatus'])

        return nil
      end
      row = anet.find_transaction(reversal.reference, since: [reversal.submitted_at - 1.hour, 30.days.ago].max)
      unless row
        # A refund appears in the unsettled list at once. After a grace period,
        # no record means nothing was refunded.
        return reversal.submitted_at < 10.minutes.ago ? { status: 'failed', message: 'The gateway has no record of this refund. Nothing was refunded.' } : nil
      end
      amount = BigDecimal(row['authAmount'].to_s) * 100
      unless row['transactionType'] == 'refundTransaction' && row['refTransId'].to_s == attempt.transaction_id && amount == reversal.amount_cents
        raise Error, 'A gateway record uses this refund reference but does not match it. Review it in the gateway portal.'
      end
      return { status: 'succeeded', transaction_id: row['transId'].to_s } if %w[refundPendingSettlement refundSettledSuccessfully].include?(row['transactionStatus'])
      return { status: 'failed', message: 'The gateway declined the refund. Nothing was refunded.' } if %w[declined voided expired].include?(row['transactionStatus'])

      nil
    rescue ArgumentError
      raise Error, 'Gateway refund amount could not be verified.'
    end

    def reconcile_nmi(reversal, attempt)
      row = nmi.transaction_by_id(attempt.transaction_id)
      return nil unless row

      if reversal.kind == 'void'
        voided = row['condition'] == 'canceled' || row['actions'].any? { |a| a['action_type'] == 'void' && a['success'] == '1' }
        return { status: 'succeeded', transaction_id: attempt.transaction_id } if voided
        return { status: 'failed', message: 'The void did not apply. Nothing was reversed.' } if %w[pendingsettlement complete].include?(row['condition'])

        return nil
      end
      # A refund of the same amount seen on the payment more times than Rupert
      # has already counted is this refund. Anything less certain stays for review.
      cents = reversal.amount_cents
      seen = row['actions'].count { |a| %w[refund credit].include?(a['action_type']) && a['success'] == '1' && a['amount'].to_s.match?(/\A\d{1,9}(?:\.\d{1,2})?\z/) && BigDecimal(a['amount']) * 100 == cents }
      counted = PosCardReversal.succeeded.where(pos_payment_attempt: attempt, kind: 'refund', amount_cents: cents).count
      seen > counted ? { status: 'succeeded', transaction_id: nil } : nil
    end

    # Voided, or refunded for more than the refunds Rupert has recorded.
    def reversed_outside_rupert?(row, attempt)
      return true if row['condition'] == 'canceled' || row['actions'].any? { |a| a['action_type'] == 'void' && a['success'] == '1' }

      at_gateway = row['actions'].sum do |a|
        next 0 unless %w[refund credit].include?(a['action_type']) && a['success'] == '1'
        raise Error, 'NMI refund amount could not be verified.' unless a['amount'].to_s.match?(/\A\d{1,9}(?:\.\d{1,2})?\z/)

        (BigDecimal(a['amount']) * 100).to_i
      end
      at_gateway > PosCardReversal.succeeded.where(pos_payment_attempt: attempt, kind: 'refund').sum(:amount_cents)
    end

    def apply(reversal, result)
      @checkout.with_lock do
        reversal.reload
        return unless reversal.unresolved?

        case result[:status]
        when 'succeeded'
          refund = nil
          if @checkout.order
            refund = @checkout.order.record_refund!(amount_cents: reversal.amount_cents, method: 'card', reason: "#{reversal.kind.capitalize}: #{reversal.reason}".truncate(250),
              reference: [reversal.kind, result[:transaction_id] || reversal.reference].join('-'))
          end
          reversal.update!(status: 'succeeded', transaction_id: result[:transaction_id], resolved_at: Time.current, core_refund: refund)
          ActivityLogger.log("pos_card_#{reversal.kind}", subject: @checkout, details: "#{format('%.2f', reversal.amount_cents / 100.0)} USD · #{reversal.reference}")
        when 'failed'
          reversal.update!(status: 'failed', failure_message: result[:message].to_s.truncate(250), resolved_at: Time.current)
        else
          reversal.update!(status: 'unknown')
          ActivityLogger.log('pos_card_reversal_needs_review', subject: @checkout, details: reversal.reference)
        end
      end
    end
  end
end
