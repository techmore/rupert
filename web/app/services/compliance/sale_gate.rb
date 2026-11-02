# frozen_string_literal: true

module Compliance
  # The pre-sale check for a whole cart (F70): item eligibility for the tender
  # plus the 21+ ID confirmation, then the manager override when one is offered.
  # Every refusal and override is written to the compliance audit trail.
  class SaleGate
    PIN_WINDOW = 15.minutes
    PIN_FAILURES = 5
    REASON_RANGE = (8..500)

    Override = Data.define(:approver_id, :pin, :reason) do
      def self.from(params)
        return unless params
        return if params[:override_user_id].blank? && params[:override_pin].blank?

        new(approver_id: params[:override_user_id].to_s, pin: params[:override_pin].to_s, reason: params[:override_reason].to_s.squish)
      end
    end

    # Result with the cart-level ID check added to the item issues.
    def self.evaluate(lines, tender:, id_checked:, policy:, processor: nil, on: Date.current)
      result = ItemEligibility.check(lines, tender: tender, processor: processor, policy: policy, on: on)
      issues = result.issues.dup
      if !id_checked && lines.any? { |line| line.catalog_item.nil? || line.catalog_item.age_restricted }
        issues << ItemEligibility::Issue.new(code: :id_not_checked, severity: :block, overridable: false, item_key: nil, item_name: nil,
          message: 'Check the customer’s ID (21 or older) and tick ID checked.')
      end
      ItemEligibility::Result.new(issues, result.tender_kind)
    end

    # Returns the approving manager (or nil when nothing needed approval).
    # Raises Blocked / OverrideRefused otherwise. Call before the sale's own
    # transaction so the refusal rows are kept.
    def self.enforce!(result, override:, location_id:, details: {}, pos_event_id: nil, pos_checkout_id: nil)
      return nil if result.allowed?

      context = { location_id: location_id, pos_event_id: pos_event_id, pos_checkout_id: pos_checkout_id }
      audit = details.merge('tender_kind' => result.tender_kind.to_s, 'issues' => result.blocking.map { |i| i.to_h.slice(:code, :item_key, :item_name).stringify_keys })
      unless override
        ComplianceEvent.record!('sale_blocked', details: audit, **context)
        raise Blocked, result
      end
      unless result.overridable?
        ComplianceEvent.record!('override_refused', reason: override.reason, details: audit.merge('refusal' => 'not_overridable'), **context)
        raise OverrideRefused.new(result, "A manager cannot override this: #{result.blocking.reject(&:overridable).map(&:message).join(' ')}")
      end

      approver = User.where(tenant_id: Current.tenant_id).find_by(id: override.approver_id)
      refusal = refusal_for(approver, override)
      if refusal
        ComplianceEvent.record!('override_refused', approver: approver, reason: override.reason, details: audit.merge('refusal' => refusal.first), **context)
        raise OverrideRefused.new(result, refusal.last)
      end
      ComplianceEvent.record!('override_granted', approver: approver, reason: override.reason, details: audit, **context)
      approver
    end

    def self.refusal_for(approver, override)
      return ['not_approver', 'Choose a manager who can approve overrides.'] unless approver&.can_approve_pos_override? && approver.pos_override_pin_set?
      return ['locked_out', "Too many wrong PINs for this manager. Try again in #{PIN_WINDOW.inspect}."] if locked_out?(approver)
      return ['reason_missing', "Give a reason of at least #{REASON_RANGE.min} characters."] unless REASON_RANGE.cover?(override.reason.length)
      return ['wrong_pin', 'That PIN is not right.'] unless approver.valid_pos_override_pin?(override.pin)

      nil
    end

    def self.locked_out?(approver)
      ComplianceEvent.where(action: 'override_refused', approver_id: approver.id).where('created_at >= ?', PIN_WINDOW.ago)
        .count { |event| event.details['refusal'] == 'wrong_pin' } >= PIN_FAILURES
    end

    # Managers who can approve at a register: active, override-capable, PIN set.
    def self.approvers
      User.where(tenant_id: Current.tenant_id).active.ordered.select { |user| user.can_approve_pos_override? && user.pos_override_pin_set? }
    end
  end
end
