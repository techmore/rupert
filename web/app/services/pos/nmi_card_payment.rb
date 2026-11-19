# frozen_string_literal: true

require 'digest'

module Pos
  class NmiCardPayment
    def self.call(checkout, nonce:)
      raise Error, 'Demo card checkout does not accept real card tokens.' if checkout.demo?
      unless nonce.is_a?(String) && nonce.match?(/\A[A-Za-z0-9_-]{10,4096}\z/)
        raise Error, 'Invalid NMI payment token.'
      end
      gateway = gateway_for(checkout)
      gateway.merchant
      attempt = nil
      checkout.with_lock do
        return checkout if checkout.paid? || checkout.unresolved?
        unless checkout.tender == 'card' && %w[ready declined].include?(checkout.status) && checkout.pos_display_session.active?
          raise Error, 'Checkout is not ready for NMI payment.'
        end
        setting = PosSetting.lock.find_by!(location: checkout.location)
        raise Error, 'NMI setup changed. Check payment status.' unless setting.lock_version == gateway.version && setting.card_enabled && setting.verified_at
        unless checkout.sandbox_payment?
          checkout.pos_session.lock!
          raise Error, 'This register is closed.' unless checkout.pos_session.status == 'open'
        end
        digest = Digest::SHA256.hexdigest(nonce)
        raise Error, 'This card token was already submitted. Check payment status.' if PosPaymentAttempt.exists?(nonce_digest: digest)
        attempt = checkout.pos_payment_attempts.create!(invoice: "RN#{SecureRandom.hex(12)}", nonce_digest: digest, submitted_at: Time.current)
        checkout.update!(status: 'processing')
      end
      # A durable attempt exists before HTTP. Never hold a DB lock over a charge.
      response = gateway.charge(attempt, nonce)
      id = response['transactionid'].to_s
      checkout.with_lock do
        return checkout if checkout.paid?
        # Declined (2), or a gateway error (3) that created no transaction.
        if response['response'] == '2' || (response['response'] == '3' && !id.match?(NmiGateway::ID))
          attempt.update!(status: 'declined', resolved_at: Time.current, decline_reason: DeclineReason.nmi(response['response_code']),
            transaction_id: id.match?(NmiGateway::ID) ? id : nil)
          checkout.update!(status: 'declined')
        else
          attempt.update!(status: 'unknown', transaction_id: id.match?(NmiGateway::ID) ? id : nil)
          checkout.update!(status: 'unknown')
        end
      end
      reconcile!(attempt) unless checkout.status == 'declined'
      checkout.reload
    rescue Error
      if attempt
        checkout.with_lock do
          unless checkout.paid?
            attempt.update!(status: 'unknown')
            checkout.update!(status: 'unknown')
          end
        end
      end
      raise
    rescue ActiveRecord::RecordNotUnique
      raise Error, 'This card token was already submitted. Check payment status.'
    end

    def self.reconcile!(attempt)
      checkout = attempt.pos_checkout
      return if checkout.paid?
      gateway = gateway_for(checkout)
      gateway.merchant
      row = gateway.transaction(attempt)
      return unless row
      unless row['transaction_id'].match?(NmiGateway::ID) && row['order_id'] == attempt.invoice &&
          row['currency'] == 'USD' && row['transaction_type'] == 'cc' &&
          (attempt.transaction_id.blank? || row['transaction_id'] == attempt.transaction_id)
        raise Error, 'NMI payment does not match this checkout.'
      end
      sales = row['actions'].select { |action| action['action_type'] == 'sale' }
      success = sales.one? && sales.first['success'] == '1' &&
        sales.first['amount'].match?(/\A\d{1,9}(?:\.\d{1,2})?\z/) &&
        BigDecimal(sales.first['amount']) * 100 == checkout.total_cents
      reversed = row['actions'].any? { |action| %w[void refund credit].include?(action['action_type']) && action['success'] == '1' }
      checkout.with_lock do
        return if checkout.paid?
        if success && !reversed && %w[pendingsettlement complete].include?(row['condition'])
          Checkout.finalize!(checkout, transaction_id: row['transaction_id'])
          attempt.update!(status: 'paid', transaction_id: row['transaction_id'], resolved_at: Time.current, **receipt_fields(row))
        elsif %w[failed canceled abandoned].include?(row['condition']) && !success
          attempt.update!(status: 'declined', transaction_id: row['transaction_id'], resolved_at: Time.current,
            decline_reason: DeclineReason.nmi(sales.first&.dig('response_code')))
          checkout.update!(status: 'declined')
        else
          raise Error, 'NMI payment is unresolved. No new charge was sent.'
        end
      end
    end

    def self.receipt_fields(row)
      brand = row['cc_type'].to_s
      auth = row['authorization_code'].to_s
      { card_last_four: row['cc_number'].to_s[/\A[0-9]{0,6}[xX*]{0,15}(\d{4})\z/, 1],
        card_brand: brand.match?(/\A[A-Za-z ]{1,30}\z/) ? brand.capitalize : nil,
        auth_code: auth.match?(/\A[A-Za-z0-9]{1,12}\z/) ? auth : nil }
    end

    def self.gateway_for(checkout)
      setting = PosSetting.find_by!(location: checkout.location)
      gateway = NmiGateway.new(setting)
      gateway.assert_checkout!(checkout)
      raise Error, 'NMI checkout is disabled.' unless setting.card_enabled && setting.verified_at
      gateway
    end
    private_class_method :gateway_for
  end
end
