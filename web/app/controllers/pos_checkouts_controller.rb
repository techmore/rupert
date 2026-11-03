# frozen_string_literal: true

class PosCheckoutsController < AuthenticatedController
  before_action do
    raise Pundit::NotAuthorizedError unless Current.user.can_use_pos?

    skip_authorization # gate: can_use_pos?; checkouts are scoped to the cashier's own display sessions
    response.headers['Cache-Control'] = 'no-store'
  end
  rescue_from Pos::Error, Ctrax::Client::Error do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end
  # Later handlers win: a compliance block also returns its issues and whether a manager may override.
  rescue_from Compliance::Blocked do |error|
    render json: error.payload, status: :unprocessable_entity
  end
  def create
    display = PosDisplaySession.find_by!(id: params[:display_id], user_id: Current.user.id)
    if params[:tender] == 'cash' && display.confirmed? && display.draft['tax_verified']
      total = display.draft['subtotal_cents'] + display.draft['tax_cents'] + display.chosen_tip_cents
      raise Pos::Error, 'Cash received is less than the total.' if Pos::Checkout.money(params[:cash_received]) < total
    end
    checkout = Pos::Checkout.prepare!(display: display, tender: params[:tender], register_id: params[:register_id],
      compliance: params.permit(:id_checked, :override_user_id, :override_pin, :override_reason).to_h.symbolize_keys)
    if checkout.tender == 'cash' || checkout.terminal_card?
      checkout.terminal_card? ? Pos::Checkout.terminal_card!(checkout) : Pos::Checkout.cash!(checkout, received: params[:cash_received])
      PosInventoryJob.perform_later(checkout.id) unless checkout.demo?
    end
    send_to_terminal(checkout) if checkout.dejavoo_terminal?
    render json: checkout.reload.receipt
  end

  # Sends (or, after a decline or cancel, re-sends) the sale to the store's
  # Dejavoo terminal. Answers at once; the terminal wait runs in a job.
  def terminal
    checkout = checkout_scope.find(params[:id])
    raise Pos::Error, 'This checkout does not use a payment terminal.' unless checkout.dejavoo_terminal?

    send_to_terminal(checkout)
    render json: checkout.reload.receipt
  end

  # Asks the terminal to stop waiting for the card. Nothing is charged twice:
  # the waiting sale reports its own result.
  def terminal_cancel
    checkout = checkout_scope.find(params[:id])
    raise Pos::Error, 'This checkout does not use a payment terminal.' unless checkout.dejavoo_terminal?

    Pos::DejavooTerminalPayment.abort!(checkout)
    render json: checkout.reload.receipt
  end

  def show
    @checkout = checkout_scope.find(params[:id])
    @coa_badges = Compliance::Catalog.register_badges(@checkout.location)
  end

  def cancel
    checkout = checkout_scope.find(params[:id])
    Pos::Checkout.cancel!(checkout)
    display = checkout.pos_display_session
    display.publish!({ 'lines' => [], 'subtotal' => '0', 'currency_code' => 'USD' }) if display.active?
    respond_to do |format|
      format.json { render json: checkout.receipt }
      format.html { redirect_to ctrax_pos_path(location_id: checkout.location_id), notice: 'Unpaid checkout cancelled.' }
    end
  end

  def reconcile
    checkout = checkout_scope.find(params[:id])
    checkout.pos_payment_attempts.where(status: %w[submitting unknown]).each { |attempt| Pos::CardPayment.reconcile!(attempt) }
    redirect_to pos_checkout_path(checkout), notice: 'Gateway status checked; no charge was sent.'
  end

  # Void or refund a gateway card payment. Money leaves the merchant account, so
  # this needs sales.write, a reason and an amount; the gateway decides void vs refund.
  def reverse
    checkout = checkout_scope.find(params[:id])
    raise Pundit::NotAuthorizedError unless Current.user.can?('sales.write')

    reversal = Pos::CardReversal.call(checkout: checkout, amount_cents: Pos::Checkout.money(params[:amount]), reason: params[:reason], user: Current.user)
    message = case reversal.status
    when 'succeeded' then "#{reversal.kind == 'void' ? 'Voided' : 'Refunded'} #{format('%.2f', reversal.amount_cents / 100.0)} USD on the original card."
    when 'failed' then "Not reversed: #{reversal.failure_message}"
    else 'The gateway outcome is uncertain. Recheck before trying again; nothing new was sent.'
    end
    redirect_to pos_checkout_path(checkout), (reversal.status == 'succeeded' ? :notice : :alert) => message
  rescue Pos::Error => e
    redirect_to pos_checkout_path(checkout), alert: e.message
  end

  def recheck_reversal
    checkout = checkout_scope.find(params[:id])
    raise Pundit::NotAuthorizedError unless Current.user.can?('sales.write')

    PosCardReversal.unresolved.where(pos_checkout: checkout).find_each { |reversal| Pos::CardReversal.reconcile!(reversal) }
    redirect_to pos_checkout_path(checkout), notice: 'Refund status checked with the gateway; nothing new was sent.'
  rescue Pos::Error => e
    redirect_to pos_checkout_path(checkout), alert: e.message
  end

  private

  def send_to_terminal(checkout)
    attempt = Pos::DejavooTerminalPayment.start!(checkout)
    PosTerminalSaleJob.perform_later(attempt.id) if attempt
  end

  def checkout_scope
    Current.user.admin? || Current.user.super_admin? ? PosCheckout.all : PosCheckout.where(user_id: Current.user.id)
  end
end
