# frozen_string_literal: true

# The self-service switch (docs/ops/self-service-billing.md). Off by default.
#
# Off: nothing here runs. Sign-up stays free, no workspace is checked against a subscription,
# and the operator billing pages and the entitlement endpoint answer 404.
#
# On: a new self-service sign-up accepts the terms, starts a trial and becomes a billable
# workspace; a billable workspace whose trial or subscription has lapsed is read-only
# (SubscriptionGate). Exempt workspaces, which is every workspace that existed before the
# switch and every workspace not created by self-service sign-up, are never checked.
module SelfService
  module_function

  def enabled?
    %w[1 true yes on].include?(ENV['RUPERT_SELF_SERVICE'].to_s.strip.downcase)
  end

  # Days a new workspace has full use before it must subscribe. No card is taken at sign-up.
  def trial_days
    bounded('RUPERT_TRIAL_DAYS', default: 14, max: 365)
  end

  # Days a workspace keeps full use after a payment fails, while Stripe retries the card.
  def grace_days
    bounded('RUPERT_BILLING_GRACE_DAYS', default: 7, max: 90)
  end

  # Stripe Tax at checkout. Off until the owner has registered for tax in the Stripe dashboard.
  def automatic_tax?
    %w[1 true yes on].include?(ENV['RUPERT_STRIPE_AUTOMATIC_TAX'].to_s.strip.downcase)
  end

  # What this request's workspace may do. An isolated workspace node holds no subscription
  # records, so it asks the control plane (WorkspaceNode.entitlement).
  def entitlement_for(tenant)
    return WorkspaceEntitlement.from_control_plane(WorkspaceNode.entitlement) if WorkspaceNode.isolated?

    WorkspaceEntitlement.for(tenant)
  end

  def bounded(key, default:, max:)
    value = Integer(ENV[key].to_s.strip, 10, exception: false)
    value && value.between?(0, max) ? value : default
  end
end
