# frozen_string_literal: true

# Turns a warehouse-sale cart into a paid canonical order. Prices and stock
# are recomputed server-side (never trusted from the browser), payment goes
# through Authorize.net with an Accept.js nonce, and on approval a Core::Order
# with its lines and a card payment are recorded and marked paid.
class WarehouseCheckoutService
  Result = Struct.new(:success?, :order, :error, keyword_init: true)

  SHIPPING_FIELDS = %i[
    shipping_name
    shipping_address1
    shipping_address2
    shipping_city
    shipping_province
    shipping_zip
    shipping_country
    shipping_phone
  ].freeze

  class << self
    def call(share:, cart:, shipping: {}, payment_nonce: nil, data_descriptor: nil)
      new(
        share: share,
        cart: cart,
        shipping: shipping,
        payment_nonce: payment_nonce,
        data_descriptor: data_descriptor
      ).call
    end
  end

  def initialize(share:, cart:, shipping: {}, payment_nonce: nil, data_descriptor: nil)
    @share = share
    @cart = cart
    @shipping = shipping
    @payment_nonce = payment_nonce
    @data_descriptor = data_descriptor
  end

  def call
    return failure('Your cart is empty.') if @cart.items.empty?
    return failure('Authorize.net is not configured.') unless AuthorizeNetClient.configured?
    return failure('Payment details are missing.') if @payment_nonce.blank?

    # Hard lock: the cart row is locked for the whole checkout so two
    # concurrent POSTs (double-click, refresh, shared cookie) serialize, and a
    # second attempt resolves to the existing order instead of charging twice.
    # Order + payment + checked_out flag commit atomically.
    result = nil
    @cart.with_lock do
      if @cart.checked_out?
        existing = Core::Order.find_by(tenant_id: @share.tenant_id, source: 'online', source_order_id: order_ref_id)
        result = if existing
                   Result.new(success?: true,
                              order: existing)
                 else
                   failure('This cart has already been checked out.')
                 end
        next result
      end

      lines = validate_lines
      if lines.is_a?(String)
        result = failure(lines)
        next result
      end

      order = create_order(lines)
      charge = AuthorizeNetClient.charge!(
        amount_cents: @cart.total_cents,
        payment_nonce: @payment_nonce,
        data_descriptor: @data_descriptor.presence || 'COMMON.ACCEPT.INAPP.PAYMENT',
        ref_id: order.source_order_id,
        invoice_number: order.order_number,
        description: "Warehouse sale · #{@share.name}"
      )

      if charge.approved?
        record_success(order, lines, charge)
        @cart.mark_checked_out!
        result = Result.new(success?: true, order: order)
      else
        result = Result.new(success?: false,
                            error: "Payment was declined#{": #{charge.message}" if charge.message.present?}")
        # Roll back the pending order: a declined charge must not leave an
        # order row behind, and the cart stays open for another attempt.
        raise ActiveRecord::Rollback
      end
    end
    result
  rescue AuthorizeNetClient::Error => e
    failure(e.message)
  rescue ActiveRecord::RecordNotUnique
    recover_already_processed!
  end

  private

  # Revalidate every line against the catalog and current stock, refreshing the
  # stored price snapshot. Returns the validated lines or an error string.
  def validate_lines
    validated = []
    @cart.items.each do |item|
      variant = item.variant
      return "#{item.title.presence || 'Item'} is no longer available." unless variant

      if item.quantity > item.available_quantity
        return "Only #{item.available_quantity} of #{variant.title} are available."
      end

      item.assign_price!(@share, variant)
      item.save!
      validated << { variant: variant, item: item }
    end
    validated
  end

  def create_order(lines)
    order = Core::Order.new(
      tenant_id: @share.tenant_id,
      source: 'online',
      source_order_id: order_ref_id,
      order_number: next_order_number,
      channel: 'warehouse',
      currency: 'USD',
      gross_cents: @cart.total_cents,
      tax_cents: 0,
      line_items: lines.sum { |line| line[:item].quantity },
      occurred_at: Time.current
    )
    SHIPPING_FIELDS.each do |field|
      order.send("#{field}=", @shipping[field]) if @shipping[field].present?
    end
    order.save!
    order
  end

  def record_success(order, lines, charge)
    lines.each do |line|
      item = line[:item]
      Core::OrderLine.create!(
        tenant_id: @share.tenant_id,
        order_id: order.id,
        sku: item.sku.presence,
        name: item.title,
        quantity: item.quantity,
        unit_cents: item.unit_cents,
        line_cents: item.line_cents
      )
    end
    Core::Payment.create!(
      tenant_id: @share.tenant_id,
      order_id: order.id,
      method: 'card',
      amount_cents: order.gross_cents,
      status: 'completed',
      reference: charge.transaction_id,
      paid_at: Time.current
    )
    order.mark_paid!
  end

  def next_order_number
    "WH-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(3).upcase}"
  end

  # Deterministic per cart so a retried checkout (charge succeeded but the
  # response was lost) reuses the same Authorize.net ref_id — Authorize.net
  # de-duplicates on it — and resolves to the same order instead of double
  # charging.
  def order_ref_id
    "wh-#{@cart.id}"
  end

  def recover_already_processed!
    @cart.reload
    return failure('This cart has already been checked out.') unless @cart.checked_out?

    existing = Core::Order.find_by(tenant_id: @share.tenant_id, source: 'online', source_order_id: order_ref_id)
    existing ? Result.new(success?: true, order: existing) : failure('This order was already processed.')
  end

  def failure(error)
    Result.new(success?: false, error: error)
  end
end
