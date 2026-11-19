# frozen_string_literal: true

# Read-only mode for a workspace whose trial or subscription has lapsed (SelfService, off by default).
#
# With the switch off this returns at its first line. With it on, exempt workspaces (every legacy
# workspace) always pass. A lapsed workspace can still open every page, so its records stay visible
# and exportable; only requests that change something are refused, except the controllers below,
# which a lapsed owner needs in order to pay, sign in or out, grant support access or delete the account.
module SubscriptionGate
  extend ActiveSupport::Concern

  ALWAYS_ALLOWED = %w[billing sessions oauth instance_sessions workspaces support_access account_deletions
                      platform platform_billing native/sessions].freeze
  READ_ONLY_MESSAGE = 'This workspace is read-only because its subscription has lapsed. Your records are safe and can still be viewed and exported. ' \
                      'The workspace owner can renew under Subscription.'

  private

  def enforce_subscription_entitlement
    return unless SelfService.enabled?
    return unless Current.user && Current.tenant

    @entitlement = SelfService.entitlement_for(Current.tenant)
    return if @entitlement.full?
    return if ALWAYS_ALLOWED.include?(controller_path)

    if request.get? || request.head?
      flash.now[:alert] ||= READ_ONLY_MESSAGE if respond_to?(:flash) && request.format.html?
      return
    end
    refuse_lapsed_write
  end

  def refuse_lapsed_write
    response.headers['Cache-Control'] = 'no-store'
    if is_a?(ActionController::Base) && request.format.html?
      redirect_back(fallback_location: '/', alert: READ_ONLY_MESSAGE, status: :see_other)
    else
      render json: { ok: false, error: 'subscription_lapsed', message: READ_ONLY_MESSAGE }, status: :payment_required
    end
  end
end
