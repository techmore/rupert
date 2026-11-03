# frozen_string_literal: true

require 'digest'

module Pos
  # Runs a register checkout on the store's Dejavoo terminal through SPIn
  # (production only after owner sign-off). Same safety rules as the NMI flow:
  #
  # - The approved-product check runs again before the terminal is asked.
  # - A durable attempt (its invoice is the SPIn ReferenceId) is saved before
  #   any request, and no database lock is held while the terminal waits.
  # - Only an approval for our ReferenceId, for exactly the checkout total, with
  #   no surcharge added, marks the checkout paid.
  # - A lost or unclear answer leaves the checkout "unknown"; reconcile! asks
  #   SPIn for that ReferenceId's status. Rupert never sends a second sale while
  #   one is unresolved.
  # - A partial approval is not a sale here: Rupert voids it at once.
  class DejavooTerminalPayment
    PROCESSOR = 'dejavoo_spin'
    # How long a "not found" status must wait before it proves no charge: the
    # terminal may still be waiting for the card when we first ask.
    NOT_FOUND_AFTER = 5.minutes
    # Longest a sale request can still be open (terminal wait plus HTTP margin).
    IN_FLIGHT = (DejavooSpinGateway::TERMINAL_TIMEOUT + 30).seconds

    DECLINED = 'The card was declined on the terminal. Try another card or another way to pay.'
    CANCELED = 'The payment was cancelled on the terminal. Nothing was charged.'
    TERMINAL_UNAVAILABLE = 'The terminal is offline or busy. Nothing was charged. Check it is on and idle, then try again.'
    VOIDED = 'The payment was voided on the terminal. Nothing was charged.'
    PARTIAL_REVERSED = 'The card was only partly approved, so Rupert reversed it. Nothing was charged. Try another card or another way to pay.'

    # Runs the whole sale in this request (tests, console). The register uses
    # start! here and run! in PosTerminalSaleJob so no web request waits on the
    # customer at the terminal.
    def self.call(checkout)
      attempt = start!(checkout)
      attempt ? run!(attempt) : checkout.reload
    end

    # Checks eligibility and setup, then saves the durable attempt and marks the
    # checkout "processing". Returns nil when it is already paid or in flight.
    def self.start!(checkout)
      raise Error, 'Demo checkout cannot use a payment terminal.' if checkout.demo?

      Checkout.assert_eligible!(PROCESSOR, checkout.lines) unless checkout.paid? || checkout.unresolved?
      gateway = gateway_for(checkout)
      checkout.with_lock do
        return nil if checkout.paid? || checkout.unresolved?
        unless checkout.tender == 'card' && %w[ready declined].include?(checkout.status) && checkout.pos_display_session.active?
          raise Error, 'Checkout is not ready for the card terminal.'
        end
        setting = PosSetting.lock.find_by!(location: checkout.location)
        raise Error, 'Terminal setup changed. Check payment status.' unless setting.lock_version == gateway.version && setting.card_enabled && setting.verified_at
        unless checkout.sandbox_payment?
          checkout.pos_session.lock!
          raise Error, 'This register is closed.' unless checkout.pos_session.status == 'open'
        end
        reference = DejavooSpinGateway.reference
        attempt = checkout.pos_payment_attempts.create!(invoice: reference, nonce_digest: Digest::SHA256.hexdigest("dejavoo_spin:#{reference}"),
          submitted_at: Time.current)
        checkout.update!(status: 'processing')
        attempt
      end
    end

    # Sends the saved attempt to the terminal once and settles the answer.
    def self.run!(attempt)
      checkout = attempt.pos_checkout
      return checkout.reload unless attempt.status == 'submitting' && checkout.status == 'processing'

      gateway = gateway_for(checkout)
      response = gateway.sale(reference: attempt.invoice, amount_cents: checkout.total_cents - checkout.tip_cents, tip_cents: checkout.tip_cents,
        invoice: checkout.reference.to_s[0, 50])
      settle!(checkout, attempt, response, gateway)
      checkout.reload
    rescue Error
      mark_unknown(checkout, attempt) if checkout
      raise
    end

    # Asks the terminal to stop waiting for the card. The pending sale then
    # answers "cancelled" (or, if the card was already read, its real result).
    def self.abort!(checkout)
      attempt = checkout.pos_payment_attempts.where(status: 'submitting').order(:id).last
      raise Error, 'No payment is waiting on the terminal.' unless attempt && checkout.status == 'processing'

      gateway_for(checkout).abort(attempt.invoice)
      attempt
    end

    # Resolves an unknown attempt from SPIn's Status for its ReferenceId.
    def self.reconcile!(attempt)
      checkout = attempt.pos_checkout
      return checkout if checkout.paid?
      # The sale request may still be waiting on the customer at the terminal.
      return checkout if attempt.status == 'submitting' && attempt.submitted_at > IN_FLIGHT.ago

      gateway = gateway_for(checkout)
      response = DejavooSpinGateway::PAYMENT_TYPES.lazy.map { |type| gateway.status(attempt.invoice, payment_type: type) }
        .find { |row| row.status_code != '1016' && row.status_code != '1008' }
      raise Error, 'Dejavoo could not report this payment. No new charge was sent.' unless response

      if response.outcome == 'not_found'
        raise Error, 'The terminal has not reported this payment yet. Wait, then check again.' if attempt.submitted_at > NOT_FOUND_AFTER.ago

        checkout.with_lock do
          return checkout if checkout.paid?

          attempt.update!(status: 'declined', resolved_at: Time.current, decline_reason: 'The terminal has no record of this payment. Nothing was charged.')
          checkout.update!(status: 'declined')
        end
        return checkout.reload
      end
      settle!(checkout, attempt, response, gateway)
      checkout.reload
    end

    def self.settle!(checkout, attempt, response, gateway)
      if response.charged? && response.voided && response.reference_id == attempt.invoice
        # Already reversed (by Rupert after a partial approval, or on the terminal).
        checkout.with_lock do
          return if checkout.paid?

          attempt.update!(status: 'declined', resolved_at: Time.current, decline_reason: VOIDED, transaction_id: response.processor_reference)
          checkout.update!(status: 'declined')
        end
      elsif response.outcome == 'partial'
        reverse_partial!(checkout, attempt, response, gateway)
      elsif response.approved? && matches?(checkout, attempt, response)
        checkout.with_lock do
          return if checkout.paid?

          Checkout.finalize!(checkout, transaction_id: response.processor_reference || attempt.invoice)
          attempt.update!(status: 'paid', transaction_id: response.processor_reference, resolved_at: Time.current,
            card_brand: response.card_brand, card_last_four: response.card_last_four, auth_code: response.auth_code)
        end
      elsif response.approved?
        # Approved, but not for this checkout's exact amount (for example the
        # terminal added a surcharge or its own tip). A person must look.
        checkout.with_lock do
          attempt.update!(status: 'unknown', transaction_id: response.processor_reference, decline_reason: DeclineReason::REVIEW)
          checkout.update!(status: 'unknown')
        end
        raise Error, 'The terminal approved a different amount. Do not charge again; a manager must check it.'
      elsif response.no_charge?
        checkout.with_lock do
          return if checkout.paid?

          attempt.update!(status: 'declined', resolved_at: Time.current, decline_reason: reason(response))
          checkout.update!(status: 'declined')
        end
      else
        mark_unknown(checkout, attempt)
        raise Error, 'The terminal did not confirm the payment. Do not charge again; check payment status.'
      end
    end

    def self.matches?(checkout, attempt, response)
      response.reference_id == attempt.invoice && response.transaction_type.to_s.casecmp?('Sale') && !response.voided &&
        response.total_cents == checkout.total_cents && response.fee_cents.to_i.zero? && response.tip_cents.to_i == checkout.tip_cents
    end

    def self.reverse_partial!(checkout, attempt, response, gateway)
      approved = response.total_cents
      voided = approved&.positive? && gateway.void(reference: attempt.invoice, amount_cents: approved, payment_type: response.payment_type || 'Credit')
      checkout.with_lock do
        if voided&.approved?
          attempt.update!(status: 'declined', resolved_at: Time.current, decline_reason: PARTIAL_REVERSED, transaction_id: response.processor_reference)
          checkout.update!(status: 'declined')
        else
          attempt.update!(status: 'unknown', decline_reason: DeclineReason::REVIEW, transaction_id: response.processor_reference)
          checkout.update!(status: 'unknown')
        end
      end
      raise Error, 'The card was partly approved and could not be reversed. A manager must void it on the terminal.' unless voided&.approved?
    end

    def self.reason(response)
      case response.outcome
      when 'declined' then response.status_code == '1012' ? CANCELED : DECLINED
      when 'unavailable' then TERMINAL_UNAVAILABLE
      else DeclineReason::SETUP
      end
    end

    def self.mark_unknown(checkout, attempt)
      checkout.with_lock do
        next if checkout.paid? || attempt.reload.status != 'submitting'

        attempt.update!(status: 'unknown')
        checkout.update!(status: 'unknown')
      end
    end

    def self.gateway_for(checkout)
      setting = PosSetting.find_by!(location: checkout.location)
      gateway = DejavooSpinGateway.new(setting)
      gateway.assert_checkout!(checkout)
      raise Error, 'Card terminal checkout is disabled.' unless setting.card_enabled && setting.verified_at

      gateway
    end
    private_class_method :gateway_for, :settle!, :matches?, :reverse_partial!, :reason, :mark_unknown
  end
end
