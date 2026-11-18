# frozen_string_literal: true

module Native
  # Phone card reader payments (Pos::DeviceReaderPayment): the register page
  # opens an attempt, the iPhone app runs the reader and reports back.
  #
  #   POST /native/pos_checkouts/:checkout_id/reader_attempt   page: open (or get) the attempt
  #   GET  /native/pos_checkouts/:checkout_id/reader_attempt   page: its confirmed status
  #   POST /native/reader_attempts/start   {token, device_id}          app: claim it, learn the amount
  #   POST /native/reader_attempts/result  {token, device_id, result}  app: report what the reader said
  #   POST /native/reader_attempts/cancel  {token, device_id}          app or page: give up before a result
  #
  # Signed-in session, workspace scope and POS permission as on the register.
  # The app's own HTTP client sends start, result and cancel with the session
  # cookie and no CSRF token; the attempt token is the proof there, as the push
  # token is for Native::PushDevicesController.
  #
  # Card data never belongs here. A request is refused when it carries any
  # field outside the short lists below, or anything shaped like a card number,
  # track data or a security code (CardData). Nothing from a refused request is
  # saved. A report is a hint: only the provider lookup marks a sale paid.
  class ReaderAttemptsController < ApplicationController
    BODY_KEYS = { 'create' => %w[authenticity_token], 'start' => %w[token device_id], 'result' => %w[token device_id result], 'cancel' => %w[token device_id] }.freeze
    CARD_DATA = 'Card details must never be sent to Rupert. Nothing was saved.'

    wrap_parameters false
    skip_forgery_protection only: %i[start result cancel]
    before_action do
      response.headers['Cache-Control'] = 'no-store'
      next head(:not_found) unless Pos::DeviceReader.enabled?
      next render(json: { error: 'You do not have permission to take payments.' }, status: :forbidden) unless Current.user.can_use_pos?

      screen_body
    end
    rescue_from Pos::Error do |error|
      render json: { error: error.message }, status: :unprocessable_entity
    end
    rescue_from Pos::DeviceReaderPayment::WrongDevice do |error|
      render json: { error: error.message }, status: :forbidden
    end
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: 'No such payment.' }, status: :not_found
    end

    def create
      attempt = Pos::DeviceReaderPayment.open!(checkout_scope.find(params[:checkout_id]))
      render json: Pos::DeviceReaderPayment.state(attempt, with_token: true)
    end

    def show
      checkout = checkout_scope.find(params[:checkout_id])
      attempt = checkout.pos_payment_attempts.where(provider: Pos::DeviceReader::PROVIDER).order(:id).last
      raise ActiveRecord::RecordNotFound unless attempt

      render json: Pos::DeviceReaderPayment.state(attempt)
    end

    def start
      render json: Pos::DeviceReaderPayment.start!(attempt_from_token, device_id: @body['device_id'])
    end

    def result
      attempt = attempt_from_token
      outcome = Pos::DeviceReaderPayment.report!(attempt, device_id: @body['device_id'], report: @body['result'])
      # The provider's own record decides. A repeat of a report enqueues nothing.
      PosDeviceReaderConfirmJob.perform_later(attempt.id, attempt.tenant_id) unless outcome == :duplicate
      render json: { status: attempt.reload.status, reported: true }
    rescue Pos::DeviceReaderPayment::AmountMismatch => e
      # Refused and not recorded, but something was approved: look it up now.
      PosDeviceReaderConfirmJob.perform_later(attempt.id, attempt.tenant_id)
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def cancel
      attempt = Pos::DeviceReaderPayment.cancel!(attempt_from_token, device_id: @body['device_id'])
      PosDeviceReaderConfirmJob.perform_later(attempt.id, attempt.tenant_id)
      render json: { status: attempt.status, reported: true }
    end

    private

    # The body and query string exactly as sent. Refuses card data first, then
    # any field this action does not take. No action takes a query string.
    def screen_body
      @body = request.request_parameters.to_h
      query = request.query_parameters.to_h
      if card_data?(@body) || card_data?(query)
        ActivityLogger.log('pos_device_reader_card_data_refused', details: "#{action_name}: a request carried card data and was refused")
        return render(json: { error: CARD_DATA }, status: :unprocessable_entity)
      end
      return if query.empty? && (@body.keys - BODY_KEYS.fetch(action_name, [])).empty?

      render json: { error: 'The request has a field Rupert does not accept.' }, status: :unprocessable_entity
    end

    def card_data?(value)
      case value
      when Hash then value.any? { |key, item| card_data?(key) || card_data?(item) }
      when Array then value.any? { |item| card_data?(item) }
      when String then CardData.contains?(value)
      when Numeric then CardData.contains?(value.to_s)
      else false
      end
    end

    def attempt_from_token
      attempt = Pos::DeviceReaderPayment.find_by_token(@body['token'])
      raise ActiveRecord::RecordNotFound unless attempt && checkout_scope.exists?(id: attempt.pos_checkout_id)

      attempt
    end

    # As on the register: a cashier's own checkouts, or any for an administrator.
    def checkout_scope
      Current.user.admin? || Current.user.super_admin? ? PosCheckout.all : PosCheckout.where(user_id: Current.user.id)
    end
  end
end
