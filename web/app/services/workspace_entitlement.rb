# frozen_string_literal: true

# What a workspace's subscription allows right now, worked out from local records only
# (never a Stripe call). Read by SubscriptionGate, the Subscription page, the operator
# billing page and the entitlement endpoint that isolated workspace nodes ask.
#
# state                          access
#   exempt         billing_exempt is set (every legacy workspace)   full, always
#   comped         the operator gave a plan until a date            full
#   trialing       inside the sign-up trial, or a Stripe trial      full
#   active         Stripe confirms a paid subscription              full
#   past_due       a payment failed                                 full during the grace period, then read-only
#   canceled       the subscription ended                           read-only
#   trial_expired  the trial ended without a subscription           read-only
#
# Read-only keeps every record visible and exportable. Nothing is deleted or hidden.
class WorkspaceEntitlement
  STATES = %w[exempt comped trialing active past_due canceled trial_expired].freeze
  FULL = 'full'
  READ_ONLY = 'read_only'

  attr_reader :state, :access, :trial_ends_at, :grace_ends_at, :comp_until

  def initialize(state:, access:, trial_ends_at: nil, grace_ends_at: nil, comp_until: nil)
    @state = state
    @access = access
    @trial_ends_at = trial_ends_at
    @grace_ends_at = grace_ends_at
    @comp_until = comp_until
  end

  def self.exempt
    new(state: 'exempt', access: FULL)
  end

  def self.for(tenant, now: Time.current)
    # nil is treated as exempt too: only an explicit false makes a workspace billable.
    return exempt unless tenant && tenant.billing_exempt == false

    row = CustomerSubscription.find_by(tenant_id: tenant.id)
    return new(state: 'comped', access: FULL, comp_until: row.comp_until) if row&.comp_until && row.comp_until > now

    trial_ends_at = row&.trial_ends_at || (tenant.created_at + SelfService.trial_days.days)
    case row&.status
    when 'active'
      new(state: 'active', access: FULL)
    when 'trialing'
      new(state: 'trialing', access: FULL, trial_ends_at: row.current_period_end || trial_ends_at)
    when 'past_due', 'unpaid'
      grace_ends_at = (row.past_due_since || row.updated_at) + SelfService.grace_days.days
      new(state: 'past_due', access: grace_ends_at > now ? FULL : READ_ONLY, grace_ends_at: grace_ends_at)
    else
      # free, incomplete, incomplete_expired, paused, canceled, or no record yet.
      if trial_ends_at > now
        new(state: 'trialing', access: FULL, trial_ends_at: trial_ends_at)
      elsif %w[canceled paused].include?(row&.status)
        new(state: 'canceled', access: READ_ONLY)
      else
        new(state: 'trial_expired', access: READ_ONLY, trial_ends_at: trial_ends_at)
      end
    end
  end

  # The answer an isolated node received from the control plane. Anything missing or
  # unrecognised means full access: a workspace is never locked by a malformed reply.
  def self.from_control_plane(payload)
    payload = {} unless payload.is_a?(Hash)
    state = STATES.include?(payload['state']) ? payload['state'] : 'exempt'
    new(state: state, access: payload['access'] == READ_ONLY ? READ_ONLY : FULL,
      trial_ends_at: parse_time(payload['trial_ends_at']), grace_ends_at: parse_time(payload['grace_ends_at']),
      comp_until: parse_time(payload['comp_until']))
  end

  def self.parse_time(value)
    Time.zone.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def full?
    access == FULL
  end

  def read_only?
    !full?
  end

  def exempt?
    state == 'exempt'
  end

  def as_json(*)
    { 'state' => state, 'access' => access, 'trial_ends_at' => trial_ends_at&.utc&.iso8601,
      'grace_ends_at' => grace_ends_at&.utc&.iso8601, 'comp_until' => comp_until&.utc&.iso8601 }
  end

  # One plain sentence for the Subscription page and the operator list.
  def summary
    case state
    when 'exempt' then 'No subscription is required for this workspace.'
    when 'comped' then "Complimentary plan until #{comp_until.to_date.to_fs(:long)}."
    when 'trialing' then trial_ends_at ? "Trial: full use until #{trial_ends_at.to_date.to_fs(:long)}." : 'Trial: full use.'
    when 'active' then 'Subscription active.'
    when 'past_due'
      full? ? "A payment failed. Full use continues until #{grace_ends_at.to_date.to_fs(:long)} while the card is retried." : 'A payment failed and the grace period has ended. The workspace is read-only until the payment is made.'
    when 'canceled' then 'The subscription has ended. The workspace is read-only; records can still be viewed and exported.'
    else 'The trial has ended. The workspace is read-only; records can still be viewed and exported.'
    end
  end
end
