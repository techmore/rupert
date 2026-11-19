# frozen_string_literal: true

module Tips
  # A worker declares the cash tips they took home for a day or a shift. Cash is real money, so the
  # row is settled at once; it is theirs alone (no pool). Declaring again for the same shift/day
  # replaces the earlier figure through a reversal, so the ledger keeps both.
  class Declare
    class Error < StandardError; end

    MAX_CENTS = 200_000

    def self.call(worker:, amount_cents:, on: nil, shift: nil, user: Current.user)
      cents = Integer(amount_cents, exception: false)
      raise Error, 'Enter the cash tips as a dollar amount.' if cents.nil? || cents.negative?
      raise Error, 'That is more than Rupert accepts for one day. Ask your manager to record it.' if cents > MAX_CENTS

      shift = ClockShift.find_by(id: shift, employee_id: worker.id) if shift.is_a?(Integer) || shift.is_a?(String)
      raise Error, 'That shift is not yours.' if shift.nil? && on.nil?

      at = shift ? [shift.ended_at || Time.current, Time.current].min : Time.zone.parse(on.to_s).change(hour: 12)
      raise Error, 'Choose a day that has already happened.' if at > Time.current
      raise Error, 'That pay period is locked. Ask your manager to add it as an adjustment.' unless PayPeriod.open_for?(TipAllocation.business_date_for(at, location_id: shift&.location_id))

      TipAllocation.transaction do
        TipAllocation.live.where(employee_id: worker.id, source_kind: 'declared', clock_shift_id: shift&.id,
          business_date: TipAllocation.business_date_for(at, location_id: shift&.location_id)).find_each do |earlier|
          earlier.reverse!(reason: 'Replaced by a new cash tip declaration', created_by: user)
        end
        next nil if cents.zero?

        TipAllocation.create!(employee: worker, clock_shift: shift, location_id: shift&.location_id, source_kind: 'declared', source_ref: shift&.id&.to_s,
          tip_method: 'cash', status: 'settled', amount_cents: cents, gross_tip_cents: cents, share_count: 1, occurred_at: at,
          business_date: TipAllocation.business_date_for(at, location_id: shift&.location_id), settled_at: Time.current, evidence: 'declared', created_by: user)
      end
    end
  end
end
