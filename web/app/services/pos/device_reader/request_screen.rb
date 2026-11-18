# frozen_string_literal: true

module Pos
  module DeviceReader
    # Decides whether a request to Native::ReaderAttemptsController may be read
    # at all. Card data never belongs in one, so every key and value is passed
    # through CardData, with two narrow exceptions for values that are random
    # by design and so now and then contain a run of digits that looks like a
    # card number:
    #
    # - `token` and `device_id`, only at the top level, only on the routes that
    #   take them, and only when the value matches its own strict format
    #   (64 lowercase hex characters; a UUID). They are then not scanned. A
    #   value that fails its format is scanned like anything else, so a card
    #   number sent as a token or identifier is still refused. Neither value is
    #   stored or logged: Rupert keeps a SHA-256 digest of each.
    # - `result.provider_reference` and `result.auth_code`, the provider's own
    #   id and approval code, whose values Rupert does not control (a numeric id
    #   can pass the card-number check; a code such as "CVC123" reads as a
    #   labelled security code). When one is well formed but card-shaped it is
    #   dropped from the report instead of refusing the report: it is only a
    #   hint, and the confirmed value comes from the provider lookup. A dropped
    #   value is never stored or logged.
    #
    # Everything else, including every other value under `result`, is scanned
    # exactly as before.
    module RequestScreen
      FIELDS = { 'create' => %w[authenticity_token], 'start' => %w[token device_id], 'result' => %w[token device_id result],
                 'cancel' => %w[token device_id], 'confirmed_status' => %w[token device_id] }.freeze
      TOKEN = /\A[0-9a-f]{64}\z/
      DEVICE_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      IDENTIFIERS = { 'token' => TOKEN, 'device_id' => DEVICE_ID }.freeze
      DROPPABLE = { 'provider_reference' => PROCESSOR_REFERENCE, 'auth_code' => AUTH_CODE }.freeze

      # status: :ok, :card_data or :unknown_field. body: what the action may
      # read. dropped: names of fields left out of body.
      Verdict = Data.define(:status, :body, :dropped)

      module_function

      def call(action, body, query = {})
        allowed = FIELDS.fetch(action, [])
        body = body.to_h
        dropped = body['result'].is_a?(Hash) ? DROPPABLE.keys.select { |key| card_shaped_hint?(key, body['result'][key]) } : []
        body = body.merge('result' => body['result'].except(*dropped)) if dropped.any?
        scanned = body.reject { |key, value| allowed.include?(key) && identifier?(key, value) }
        return Verdict.new(status: :card_data, body: {}, dropped: []) if card_data?(scanned) || card_data?(query.to_h)
        return Verdict.new(status: :unknown_field, body: {}, dropped: []) unless query.to_h.empty? && (body.keys - allowed).empty?

        Verdict.new(status: :ok, body: body, dropped: dropped)
      end

      def identifier?(key, value) = IDENTIFIERS.key?(key) && value.is_a?(String) && value.match?(IDENTIFIERS.fetch(key))

      def card_shaped_hint?(key, value) = value.is_a?(String) && value.match?(DROPPABLE.fetch(key)) && CardData.contains?(value)

      def card_data?(value)
        case value
        when Hash then value.any? { |key, item| card_data?(key) || card_data?(item) }
        when Array then value.any? { |item| card_data?(item) }
        when String then CardData.contains?(value)
        when Numeric then CardData.contains?(value.to_s)
        else false
        end
      end
    end
  end
end
