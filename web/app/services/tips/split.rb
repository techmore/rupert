# frozen_string_literal: true

module Tips
  # Decides who receives one tip (docs/time-and-pay/DECISIONS.md, "Card tip attribution") and
  # returns the TipAllocation attribute rows, without saving. The caller adds source and status.
  #
  #   Tips::Split.new(gross_cents: 500, at: Time, location_id: 'loc', cashier: employee_or_nil, evidence: 'checkout').rows
  #
  # Pool (owner rule): split evenly among everyone clocked in at `at` (at this store when the rules
  # pool by store; punches with no store count everywhere), administrators and ineligible workers
  # excluded, whole cents, the remainder to the earliest clock-in. Direct: the cashier keeps it,
  # falling back to the pool. Nobody eligible: one unassigned row.
  class Split
    attr_reader :gross_cents, :at, :location_id, :cashier, :evidence, :rules

    def initialize(gross_cents:, at:, location_id: nil, cashier: nil, evidence: 'time_register', rules: nil)
      @gross_cents = gross_cents.to_i
      @at = at
      @location_id = location_id.presence
      @cashier = cashier
      @evidence = evidence
      @rules = rules || TimeRules.for(@location_id)
    end

    def rows
      return [] if gross_cents.zero?

      if rules.tip_method == 'direct' && cashier&.tip_eligible_for_pool?
        shift = shifts_at.detect { |s| s.employee_id == cashier.id }
        return [row(cashier, shift, gross_cents, 1, 'direct')]
      end

      sharers = eligible_shifts
      return [row(nil, nil, gross_cents, 0, 'pool')] if sharers.empty?

      share, remainder = gross_cents.divmod(sharers.size)
      sharers.each_with_index.map do |shift, index|
        row(shift.employee, shift, share + (index.zero? ? remainder : 0), sharers.size, 'pool')
      end
    end

    # Everyone clocked in at `at`, earliest clock-in first, one shift per worker.
    def shifts_at
      @shifts_at ||= begin
        scope = ClockShift.where('started_at <= ? AND (ended_at IS NULL OR ended_at > ?)', at, at).includes(:employee).order(:started_at, :id)
        scope = scope.where(location_id: [location_id, nil]) if location_id && rules.tip_pool_by_location?
        scope.to_a.select { |s| s.employee && at < s.counted_end(Time.current) }.uniq(&:employee_id)
      end
    end

    def eligible_shifts
      shifts_at.select { |s| s.employee.active? && s.employee.tip_eligible_for_pool? }
    end

    private

    def row(employee, shift, amount, share_count, tip_method)
      { employee_id: employee&.id, clock_shift_id: shift&.id, location_id: location_id, tip_method: tip_method,
        amount_cents: amount, gross_tip_cents: gross_cents, share_count: share_count, occurred_at: at,
        business_date: TipAllocation.business_date_for(at, location_id: location_id), evidence: evidence }
    end
  end
end
