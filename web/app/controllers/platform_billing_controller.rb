# frozen_string_literal: true

# Operator view of workspace subscriptions (SelfService, off by default): every workspace with its
# plan and state, and the two manual levers: exempt a workspace, or comp a plan until a date.
# Platform administrators only (PlatformController's gate). The routes exist only while the switch is on.
class PlatformBillingController < PlatformController
  def index
    @tenants = Tenant.order(:name).limit(500)
    @subscriptions = CustomerSubscription.where(tenant_id: @tenants.map(&:id)).index_by(&:tenant_id)
    @entitlements = @tenants.to_h { |tenant| [tenant.id, WorkspaceEntitlement.for(tenant)] }
  end

  def update
    tenant = Tenant.find(params[:id])
    case params[:change].to_s
    when 'exempt' then exempt(tenant)
    when 'billable' then make_billable(tenant)
    when 'comp' then comp(tenant)
    when 'end_comp' then end_comp(tenant)
    else redirect_to(platform_billing_path, alert: 'Choose a change to make.')
    end
  end

  private

  def exempt(tenant)
    tenant.update!(billing_exempt: true)
    record(tenant, 'marked exempt')
    redirect_to platform_billing_path, notice: "#{tenant.name} is exempt: it is never checked against a subscription."
  end

  # Making a workspace billable can end in read-only mode, so it asks for the workspace address
  # typed out, never applies to the operator's own home workspace, and always starts a full trial.
  def make_billable(tenant)
    if tenant.id == Current.user.tenant_id
      return redirect_to(platform_billing_path, alert: 'Your own home workspace stays exempt.')
    end
    unless params[:confirm_subdomain].to_s.strip == tenant.subdomain
      return redirect_to(platform_billing_path, alert: "Type the workspace address (#{tenant.subdomain}) to make it billable. Nothing was changed.")
    end

    Tenant.transaction do
      row = CustomerSubscription.find_or_create_by!(tenant: tenant)
      row.update!(trial_ends_at: SelfService.trial_days.days.from_now) unless row.stripe_subscription_id.present?
      tenant.update!(billing_exempt: false)
    end
    record(tenant, 'made billable')
    redirect_to platform_billing_path, notice: "#{tenant.name} is now billable. It has full use for #{helpers.pluralize(SelfService.trial_days, 'day')} before it must subscribe."
  end

  def comp(tenant)
    date = Date.iso8601(params[:comp_until].to_s)
    unless date > Time.zone.today && date <= 5.years.from_now.to_date
      return redirect_to(platform_billing_path, alert: 'Choose an end date in the future, at most five years ahead.')
    end

    row = CustomerSubscription.find_or_create_by!(tenant: tenant)
    row.update!(comp_until: date.end_of_day, comp_note: params[:comp_note].to_s.strip.first(200).presence)
    record(tenant, "comped until #{date.iso8601}")
    redirect_to platform_billing_path, notice: "#{tenant.name} has a complimentary plan until #{date.to_fs(:long)}. Stripe was not changed."
  rescue Date::Error
    redirect_to platform_billing_path, alert: 'Enter the end date as a calendar date.'
  end

  def end_comp(tenant)
    CustomerSubscription.find_by(tenant: tenant)&.update!(comp_until: nil, comp_note: nil)
    record(tenant, 'complimentary plan ended')
    redirect_to platform_billing_path, notice: "The complimentary plan for #{tenant.name} has ended."
  end

  def record(tenant, change)
    ActivityLogger.log('workspace_billing_changed', subject: tenant, details: change)
  end
end
