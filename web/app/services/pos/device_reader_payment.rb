# frozen_string_literal: true

require 'digest'
require 'openssl'

module Pos
  # A register checkout paid on a card reader the phone app runs (see
  # Pos::DeviceReader). Same safety rules as Pos::DejavooTerminalPayment, with
  # the same attempt and checkout statuses:
  #
  # - open! saves a durable attempt (its invoice is the provider reference) and
  #   marks the checkout "processing" before any reader runs. One unresolved
  #   attempt per checkout: asking again returns the same one.
  # - The server fixes amount, currency and reference. The phone gets them from
  #   start! with the attempt's token; the page never passes an amount.
  # - report! and cancel! only record a hint and move the attempt to "unknown".
  #   Nothing the phone says marks a sale paid.
  # - reconcile! asks the provider about our reference. Only an approval for
  #   that reference, for exactly the checkout total, with no fee added, marks
  #   the checkout paid. A different amount is held for review. A partial
  #   approval is voided at once. A lost report is resolved the same way by
  #   PosPaymentReconciliationJob.
  # - Rupert never asks for a second charge while one is unresolved, and never
  #   retries a sale.
  class DeviceReaderPayment
    PROVIDER = DeviceReader::PROVIDER
    # How long the phone may keep the reader open for one attempt.
    READER_WINDOW = 3.minutes
    # How long "no record" must wait before it proves no charge.
    NOT_FOUND_AFTER = READER_WINDOW + 2.minutes
    REPORT_STATUSES = %w[approved declined cancelled failed].freeze
    REPORT_KEYS = %w[status provider_reference amount_cents card_brand last_four entry_method auth_code].freeze
    DEVICE_ID = DeviceReader::RequestScreen::DEVICE_ID
    TOKEN = DeviceReader::RequestScreen::TOKEN
    # How many references open! may draw to avoid a card-shaped reference or token.
    REDRAWS = 20

    DECLINED = 'The card was declined on the phone. Try another card or another way to pay.'
    CANCELED = 'The payment was cancelled on the phone. Nothing was charged.'
    NO_RECORD = 'The payment provider has no record of this payment. Nothing was charged.'
    VOIDED = 'The payment was voided. Nothing was charged.'
    PARTIAL_REVERSED = 'The card was only partly approved, so Rupert reversed it. Nothing was charged. Try another card or another way to pay.'

    # The request names a device other than the one that started the reader.
    class WrongDevice < Error; end
    # An approved report for an amount other than the checkout total.
    class AmountMismatch < Error; end

    class << self
      # The attempt's single-use token. Derived, never stored: only its digest
      # is kept (nonce_digest), so a database copy cannot report a result.
      def token_for(attempt)
        key = Rails.application.key_generator.generate_key('pos device reader attempt token', 32)
        OpenSSL::HMAC.hexdigest('SHA256', key, "#{attempt.tenant_id}:#{attempt.invoice}")
      end

      def token_digest(token) = Digest::SHA256.hexdigest("#{PROVIDER}:#{token}")

      def device_digest(device_id)
        raise Error, 'Send the app install identifier.' unless device_id.is_a?(String) && device_id.match?(DEVICE_ID)

        Digest::SHA256.hexdigest("#{PROVIDER}:device:#{device_id.downcase}")
      end

      # The attempt for a token, in the current workspace only.
      def find_by_token(token)
        return nil unless token.is_a?(String) && token.match?(TOKEN)

        PosPaymentAttempt.find_by(provider: PROVIDER, nonce_digest: token_digest(token))
      end

      # Saves the durable attempt, or returns the one already open (or paid).
      def open!(checkout)
        raise Error, 'Phone card reader payments are not enabled.' unless DeviceReader.enabled?
        raise Error, 'Demo checkout cannot use a card reader.' if checkout.demo?

        Checkout.assert_eligible!(PROVIDER, checkout.lines) unless checkout.paid? || checkout.unresolved?
        gateway = gateway_for(checkout)
        created = false
        attempt = checkout.with_lock do
          existing = checkout.pos_payment_attempts.where(provider: PROVIDER, status: checkout.paid? ? 'paid' : %w[submitting unknown]).order(:id).last
          next existing if existing
          raise Error, 'Payment is paid or unresolved. Check payment status.' if checkout.paid? || checkout.unresolved?
          unless checkout.tender == 'card' && %w[ready declined].include?(checkout.status) && checkout.pos_display_session.active?
            raise Error, 'Checkout is not ready for the card reader.'
          end

          setting = PosSetting.lock.find_by!(location: checkout.location)
          raise Error, 'Card reader setup changed. Check payment status.' unless setting.lock_version == gateway.version && setting.card_enabled && setting.verified_at
          unless checkout.sandbox_payment?
            checkout.pos_session.lock!
            raise Error, 'This register is closed.' unless checkout.pos_session.status == 'open'
          end
          created = true
          row = checkout.pos_payment_attempts.new(provider: PROVIDER, submitted_at: Time.current)
          row.tenant_id = checkout.tenant_id
          # Defence in depth: a reference or token that happens to look like a
          # card number works here (RequestScreen), but a log redactor or
          # another system on its way might not agree. Draw again, a few times.
          REDRAWS.times do
            row.invoice = DeviceReader.reference
            break unless CardData.contains?(row.invoice) || CardData.contains?(token_for(row))
          end
          row.nonce_digest = token_digest(token_for(row))
          row.save!
          checkout.update!(status: 'processing')
          row
        end
        ActivityLogger.log('pos_device_reader_attempt_opened', subject: checkout, details: attempt.invoice) if created
        attempt
      end

      # The phone claims the attempt and learns what to charge. The first
      # device to ask owns the attempt; another device is refused.
      def start!(attempt, device_id:)
        raise Error, 'Phone card reader payments are not enabled.' unless DeviceReader.enabled?

        digest = device_digest(device_id)
        checkout = attempt.pos_checkout
        gateway = gateway_for(checkout)
        checkout.with_lock do
          attempt.reload
          raise WrongDevice, 'Another device is already taking this payment.' if attempt.device_digest && attempt.device_digest != digest
          raise Error, 'This payment is no longer waiting for a card. Check payment status.' unless attempt.status == 'submitting' && checkout.status == 'processing'
          raise Error, 'This payment request expired. Check payment status, then start again.' if expires_at(attempt) <= Time.current

          attempt.update!(device_digest: digest) unless attempt.device_digest
        end
        { reference: attempt.invoice, amount_cents: checkout.total_cents, tip_cents: checkout.tip_cents, currency: DeviceReader::CURRENCY,
          expires_at: expires_at(attempt).iso8601, reader: gateway.reader_params }
      end

      # Records what the phone says happened. A hint only: the attempt moves to
      # "unknown" (reported, awaiting confirmation) and the caller then asks the
      # provider. Repeats and late reports change nothing.
      # Returns :recorded, :duplicate or :late.
      def report!(attempt, device_id:, report:)
        digest = device_digest(device_id)
        checkout = attempt.pos_checkout
        clean = clean_report(report)
        if clean['status'] == 'approved' && clean['amount_cents'] != checkout.total_cents
          raise WrongDevice, 'This payment was started on another device.' unless attempt.device_digest == digest

          raise AmountMismatch, 'The reported amount does not match this checkout. Nothing was recorded; Rupert is checking with the payment provider.'
        end

        outcome = checkout.with_lock do
          attempt.reload
          raise WrongDevice, 'This payment was started on another device.' unless attempt.device_digest && attempt.device_digest == digest
          next :duplicate if attempt.device_reported_at

          # New information: let the next lookup run now rather than after the sweep's wait.
          attempt.update!(device_report_json: clean.to_json, device_reported_at: Time.current, reconciliation_checked_at: nil)
          next :late unless attempt.status == 'submitting' || attempt.status == 'unknown'

          attempt.update!(status: 'unknown')
          checkout.update!(status: 'unknown') unless checkout.paid?
          :recorded
        end
        ActivityLogger.log('pos_device_reader_result_reported', subject: checkout, details: "#{clean['status']} · #{attempt.invoice}#{' · late' if outcome == :late}") unless outcome == :duplicate
        outcome
      end

      # The cashier gave up before any result was reported. Still a hint: the
      # provider lookup decides whether a card was charged.
      def cancel!(attempt, device_id: nil)
        checkout = attempt.pos_checkout
        digest = device_id.nil? ? nil : device_digest(device_id)
        checkout.with_lock do
          attempt.reload
          raise WrongDevice, 'This payment was started on another device.' if attempt.device_digest && attempt.device_digest != digest
          raise Error, 'A result was already reported for this payment. Check payment status.' unless attempt.status == 'submitting' && attempt.device_reported_at.nil?

          attempt.update!(status: 'unknown', device_report_json: { 'status' => 'cancelled' }.to_json, device_reported_at: Time.current,
            reconciliation_checked_at: nil)
          checkout.update!(status: 'unknown')
        end
        ActivityLogger.log('pos_device_reader_cancel_requested', subject: checkout, details: attempt.invoice)
        attempt
      end

      # Resolves an attempt from the provider's record of its reference. Read
      # only, except that a partial approval is voided. Called by
      # Pos::CardPayment.reconcile! (the sweep) and PosDeviceReaderConfirmJob.
      def reconcile!(attempt)
        checkout = attempt.pos_checkout
        return checkout if attempt.status == 'paid'

        gateway = gateway_for(checkout)
        result = gateway.lookup(attempt.invoice)
        return settle!(checkout, attempt, result, gateway) unless result.outcome == 'not_found'
        return checkout if attempt.status == 'declined'

        # Phone and provider agree nothing was charged: no need to wait.
        reported = attempt.reload.device_report['status']
        agreed = %w[declined cancelled].include?(reported)
        if !agreed && attempt.submitted_at > NOT_FOUND_AFTER.ago
          # The reader may still be waiting for the card.
          return checkout if attempt.status == 'submitting'

          raise Error, 'The payment provider has not reported this payment yet. Wait, then check again.'
        end
        if reported == 'approved'
          # The phone says a card was approved and the provider still has no
          # record. That is not proof of no charge: a person must look, and the
          # sweep keeps asking in case the record appears.
          hold_for_review!(checkout, attempt, nil)
          raise Error, 'The phone reported an approval the payment provider has no record of. Do not charge again; a manager must check it.'
        end
        reason = if agreed
          reported == 'cancelled' ? CANCELED : DECLINED
        else
          NO_RECORD
        end
        decline!(checkout, attempt, reason)
      end

      # What the app and the register page may know about an attempt. The token
      # is included only while the reader has not reported.
      def state(attempt, with_token: false)
        checkout = attempt.pos_checkout
        body = { status: attempt.status, reported: attempt.device_reported_at.present?, reference: attempt.invoice,
                 amount_cents: checkout.total_cents, currency: DeviceReader::CURRENCY, expires_at: expires_at(attempt).iso8601,
                 needs_review: attempt.decline_reason == DeclineReason::REVIEW, message: attempt.status == 'paid' ? nil : attempt.decline_reason,
                 checkout: checkout.receipt }
        body[:token] = token_for(attempt) if with_token && attempt.status == 'submitting'
        body
      end

      def expires_at(attempt) = attempt.submitted_at + READER_WINDOW

      # Keeps only the whitelisted, well-formed fields of a phone report.
      def clean_report(report)
        raise Error, 'Send a payment result.' unless report.is_a?(Hash)

        report = report.transform_keys(&:to_s)
        raise Error, 'The payment result has a field Rupert does not accept.' if (report.keys - REPORT_KEYS).any?
        raise Error, 'Unknown payment result status.' unless REPORT_STATUSES.include?(report['status'])

        amount = report['amount_cents']
        valid = (amount.nil? || (amount.is_a?(Integer) && amount.between?(1, 99_999_99))) &&
          optional?(report['provider_reference'], DeviceReader::PROCESSOR_REFERENCE) && optional?(report['auth_code'], DeviceReader::AUTH_CODE) &&
          optional?(report['last_four'], DeviceReader::LAST_FOUR) &&
          (report['card_brand'].nil? || DeviceReader::CARD_BRANDS.include?(report['card_brand'])) &&
          (report['entry_method'].nil? || DeviceReader::ENTRY_METHODS.include?(report['entry_method']))
        raise Error, 'The payment result is not in the accepted form.' unless valid
        raise Error, 'An approved result must say the amount.' if report['status'] == 'approved' && amount.nil?

        report.slice(*REPORT_KEYS).compact
      end

      private

      def optional?(value, pattern) = value.nil? || (value.is_a?(String) && value.match?(pattern))

      def settle!(checkout, attempt, result, gateway)
        ours = result.reference_id == attempt.invoice
        if result.charged? && result.voided && ours
          # Already reversed (by Rupert after a partial approval, or at the provider).
          attempt.status == 'declined' ? checkout.reload : decline!(checkout, attempt, VOIDED, transaction_id: result.processor_reference)
        elsif result.outcome == 'partial' && ours
          reverse_partial!(checkout, attempt, result, gateway)
        elsif result.approved? && matches?(checkout, attempt, result)
          approve!(checkout, attempt, result)
        elsif result.charged?
          # Approved, but not for this checkout's exact amount (for example the
          # reader added a fee or its own tip), or not as a sale. A person must look.
          hold_for_review!(checkout, attempt, result)
          raise Error, 'The card reader approved a different amount. Do not charge again; a manager must check it.'
        elsif result.no_charge?
          attempt.status == 'declined' ? checkout.reload : decline!(checkout, attempt, result.outcome == 'cancelled' ? CANCELED : DECLINED)
        else
          mark_unknown(checkout, attempt)
          raise Error, 'The payment provider did not confirm the payment. Do not charge again; check payment status.'
        end
      end

      def matches?(checkout, attempt, result)
        result.reference_id == attempt.invoice && result.kind == 'sale' && !result.voided && result.currency == DeviceReader::CURRENCY &&
          result.total_cents == checkout.total_cents && result.fee_cents.to_i.zero? && result.tip_cents.to_i == checkout.tip_cents
      end

      # A confirmed approval. Normally the attempt is the checkout's only open
      # one. A late approval (the attempt was already given up, and the checkout
      # has since been paid another way, cancelled, or has a newer attempt open)
      # cannot pay it: that charge is held for review instead.
      def approve!(checkout, attempt, result)
        late = false
        checkout.with_lock do
          attempt.reload
          next if attempt.status == 'paid'

          if blocked?(checkout, attempt)
            late = true
            attempt.update!(transaction_id: result.processor_reference, decline_reason: DeclineReason::REVIEW)
          else
            Checkout.finalize!(checkout, transaction_id: result.processor_reference || attempt.invoice)
            attempt.update!(status: 'paid', transaction_id: result.processor_reference, resolved_at: Time.current, decline_reason: nil,
              card_brand: result.card_brand, card_last_four: result.card_last_four, auth_code: result.auth_code)
          end
        end
        raise Error, 'A card was approved for a payment Rupert had already closed. Do not charge again; a manager must void or refund it.' if late

        checkout.reload
      end

      def blocked?(checkout, attempt)
        checkout.paid? || checkout.status == 'cancelled' ||
          checkout.pos_payment_attempts.where(status: %w[submitting unknown]).where.not(id: attempt.id).exists?
      end

      # result: the provider's answer, or nil when it has no record.
      def hold_for_review!(checkout, attempt, result)
        checkout.with_lock do
          attempt.reload
          reference = result&.processor_reference || attempt.transaction_id
          if blocked?(checkout, attempt)
            attempt.update!(transaction_id: reference, decline_reason: DeclineReason::REVIEW)
          else
            attempt.update!(status: 'unknown', transaction_id: reference, decline_reason: DeclineReason::REVIEW)
            checkout.update!(status: 'unknown')
          end
        end
      end

      def reverse_partial!(checkout, attempt, result, gateway)
        approved = result.total_cents
        voided = approved&.positive? && gateway.void(reference: attempt.invoice, amount_cents: approved)
        reversed = voided && voided.charged? && voided.voided
        if reversed
          decline!(checkout, attempt, PARTIAL_REVERSED, transaction_id: result.processor_reference) unless attempt.status == 'declined'
        else
          hold_for_review!(checkout, attempt, result)
          raise Error, 'The card was partly approved and could not be reversed. A manager must void it with the payment provider.'
        end
        checkout.reload
      end

      def decline!(checkout, attempt, reason, transaction_id: nil)
        checkout.with_lock do
          next if checkout.paid? || !%w[submitting unknown].include?(attempt.reload.status)

          attempt.update!(status: 'declined', resolved_at: Time.current, decline_reason: reason, transaction_id: transaction_id || attempt.transaction_id)
          checkout.update!(status: 'declined')
        end
        checkout.reload
      end

      def mark_unknown(checkout, attempt)
        checkout.with_lock do
          next if checkout.paid? || attempt.reload.status != 'submitting'

          attempt.update!(status: 'unknown')
          checkout.update!(status: 'unknown')
        end
      end

      def gateway_for(checkout)
        setting = PosSetting.find_by!(location: checkout.location)
        gateway = DeviceReader.gateway(setting)
        gateway.assert_checkout!(checkout)
        raise Error, 'Phone card reader checkout is disabled.' unless setting.card_enabled && setting.verified_at

        gateway
      end
    end
  end
end
