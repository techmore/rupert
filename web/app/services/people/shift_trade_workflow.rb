# frozen_string_literal: true

module People
  # Give away, swap and pick up planned shifts (docs/time-and-pay/DECISIONS.md "Trades").
  #
  #   offer(shift, kind:, by:, …)         the owner offers it (give/swap) or a worker claims an open one (pickup)
  #   accept(trade, by:)                  a colleague takes a give-away / agrees to a swap
  #   review(trade, reviewer:, approve:)  manager decision (the approvals inbox calls this)
  #   cancel(trade, by:)                  the person who offered or accepted withdraws
  #   expire_stale!                       open trades whose shift already started
  #
  # The schedule only changes inside `apply!`, under the tenant writer lock, after the guardrails pass.
  class ShiftTradeWorkflow
    class Error < StandardError; end

    class << self
      def offer(shift, kind:, by:, to_employee: nil, counter_shift: nil, note: nil)
        raise Error, 'Choose give away, swap or pick up.' unless People::ShiftTrade::KINDS.include?(kind.to_s)
        raise Error, 'Only posted shifts can be traded.' unless shift.published? && !shift.cancelled?
        raise Error, 'This shift has already started.' if shift.starts_at <= Time.current

        worker = worker_for(by)
        return pickup(shift, worker: worker, by: by, note: note) if kind.to_s == 'pickup'

        trade = nil
        lock do
          raise Error, 'You can only offer your own shift.' unless shift.employee_id == worker.id

          if kind.to_s == 'swap'
            raise Error, 'Choose the colleague’s shift to swap with.' if counter_shift.nil?
            if counter_shift.employee_id.nil? || counter_shift.employee_id == worker.id || !counter_shift.published? || counter_shift.cancelled?
              raise Error, 'Pick a posted shift that belongs to a colleague.'
            end

            to_employee = counter_shift.employee
          end
          trade = People::ShiftTrade.create!(scheduled_shift: shift, kind: kind.to_s, from_employee: worker, to_employee: to_employee,
            counter_shift: counter_shift, requested_by: by, note: note, status: 'open')
        end
        notify_offer(trade)
        ActivityLogger.log('shift_trade_offered', subject: trade, details: "#{trade.kind_label}: #{shift_label(shift)}", actor: by)
        trade
      end

      # The colleague takes a give-away or agrees to a swap. Guardrails decide; the store's approval
      # policy decides whether the shift moves now or waits for a manager.
      def accept(trade, by:, counter_shift: nil)
        worker = worker_for(by)
        lock do
          trade.reload
          raise Error, 'This offer is no longer open.' unless trade.status == 'open'
          raise Error, 'You cannot take your own shift.' if trade.from_employee_id == worker.id
          raise Error, 'This swap was offered to someone else.' if trade.kind == 'swap' && trade.to_employee_id != worker.id

          trade.counter_shift ||= counter_shift
          checks = checks_for(trade, taker: worker)
          raise Error, blocking_message(checks) if blocked?(checks)

          trade.update!(to_employee: worker, status: 'accepted', accepted_at: Time.current, checks_json: checks.to_json)
        end
        ActivityLogger.log('shift_trade_accepted', subject: trade, details: shift_label(trade.scheduled_shift), actor: by)
        finish_or_queue(trade, worker: worker)
      end

      def review(trade, reviewer:, approve:, note: nil)
        raise Error, 'Only schedule managers can review trades.' unless reviewer && (reviewer.can?('schedule.write') || reviewer.can?('hr.write'))
        raise Error, 'Another manager must review a trade involving your own shift.' if involves?(trade, reviewer)
        raise Error, 'This store is outside your scope.' unless reviewer.manages_location?(trade.scheduled_shift.location_id)

        lock do
          trade.reload
          raise Error, 'This trade is not waiting for review.' unless trade.status == 'accepted'

          if approve
            checks = checks_for(trade, taker: trade.to_employee)
            raise Error, blocking_message(checks) if blocked?(checks)

            apply!(trade)
            trade.update!(status: 'approved', reviewed_by: reviewer, reviewed_at: Time.current, review_note: note, checks_json: checks.to_json)
          else
            trade.update!(status: 'denied', reviewed_by: reviewer, reviewed_at: Time.current, review_note: note)
          end
        end
        notify_decision(trade, approved: approve, note: note)
        ActivityLogger.log(approve ? 'shift_trade_approved' : 'shift_trade_denied', subject: trade, details: shift_label(trade.scheduled_shift), actor: reviewer)
        trade
      end

      def cancel(trade, by:)
        worker = worker_for(by, allow_nil: true)
        manager = by.can?('schedule.write') || by.can?('hr.write')
        lock do
          trade.reload
          raise Error, 'This trade is already closed.' unless trade.live?
          raise Error, 'Only the people in this trade can cancel it.' unless manager || (worker && [trade.from_employee_id, trade.to_employee_id].include?(worker.id))

          trade.update!(status: 'cancelled', reviewed_at: Time.current)
        end
        ActivityLogger.log('shift_trade_cancelled', subject: trade, details: shift_label(trade.scheduled_shift), actor: by)
        trade
      end

      def expire_stale!
        People::ShiftTrade.live.joins(:scheduled_shift).where('scheduled_shifts.starts_at <= ?', Time.current)
          .find_each { |trade| trade.update!(status: 'expired') }
      end

      private

      def pickup(shift, worker:, by:, note:)
        trade = nil
        lock do
          shift.reload
          raise Error, 'This shift already belongs to someone.' unless shift.open?

          checks = People::TradeGuardrails.check(shift, worker)
          raise Error, blocking_message(checks) if blocked?(checks)

          trade = People::ShiftTrade.create!(scheduled_shift: shift, kind: 'pickup', to_employee: worker, requested_by: by, note: note,
            status: 'accepted', accepted_at: Time.current, checks_json: checks.to_json)
        end
        ActivityLogger.log('shift_trade_offered', subject: trade, details: "Pick up: #{shift_label(shift)}", actor: by)
        finish_or_queue(trade, worker: worker)
      end

      def worker_for(user, allow_nil: false)
        worker = TimeClockService.worker_for(user)
        raise Error, 'Ask an administrator to link your staff record first.' if worker.nil? && !allow_nil

        worker
      end

      def lock
        People::ShiftTrade.transaction do
          Tenant.where(id: Current.tenant_id).update_all('updated_at = updated_at')
          yield
        end
      end

      def checks_for(trade, taker:)
        checks = People::TradeGuardrails.check(trade.scheduled_shift, taker, counter_shift: trade.counter_shift)
        if trade.kind == 'swap' && trade.counter_shift && trade.from_employee
          checks += People::TradeGuardrails.check(trade.counter_shift, trade.from_employee, counter_shift: trade.scheduled_shift)
            .map { |c| c.merge('message' => "For #{trade.from_employee.name}: #{c['message']}") }
        end
        checks
      end

      def blocked?(checks) = checks.any? { |c| c['level'] == 'block' }

      def finish_or_queue(trade, worker:)
        shift = trade.scheduled_shift
        if TimeRules.for(shift.location_id).trade_requires_approval?
          TimeNotifier.approval_needed(TimeNotifier.reviewers_for('schedule.write', location_id: shift.location_id),
            what: "#{trade.kind_label.downcase} #{shift_label(shift)}", who: worker.name,
            url: Rails.application.routes.url_helpers.people_shift_trade_path(trade), key: "trade:#{trade.id}")
        else
          lock do
            trade.reload
            apply!(trade)
            trade.update!(status: 'approved', reviewed_at: Time.current)
          end
          notify_decision(trade, approved: true)
        end
        trade
      end

      # Moves the shift(s). Swaps exchange both; give-aways and pickups reassign one.
      def apply!(trade)
        shift = trade.scheduled_shift
        now = Time.current
        if trade.kind == 'swap'
          other = trade.counter_shift
          from_id = shift.employee_id
          # Free one first so the overlap validation never sees both on one person.
          shift.update!(employee_id: nil, last_changed_at: now)
          other.update!(employee_id: from_id, last_changed_at: now)
        end
        shift.update!(employee_id: trade.to_employee_id, last_changed_at: now)
      end

      def involves?(trade, user)
        [trade.from_employee&.user_id, trade.to_employee&.user_id, trade.requested_by_id].compact.include?(user.id)
      end

      def blocking_message(checks)
        checks.select { |c| c['level'] == 'block' }.map { |c| c['message'] }.join(' ')
      end

      def shift_label(shift)
        "#{shift.starts_at.strftime('%a %b %-d')} · #{shift.time_label}"
      end

      def notify_offer(trade)
        shift = trade.scheduled_shift
        url = Rails.application.routes.url_helpers.employee_trades_path
        users = if trade.kind == 'swap'
                  [trade.to_employee&.user].compact
                else
                  People::Employee.active.where.not(id: trade.from_employee_id).select { |e| e.works_at?(shift.location_id) }.filter_map(&:user)
                end
        TimeNotifier.trade_offer(users, trade: trade, url: url)
      end

      def notify_decision(trade, approved:, note: nil)
        url = Rails.application.routes.url_helpers.employee_trades_path
        [trade.from_employee, trade.to_employee].compact.uniq.each do |employee|
          next if employee.user.nil?

          TimeNotifier.approval_decided(employee.user, what: "#{trade.kind_label}: #{shift_label(trade.scheduled_shift)}", approved: approved,
            url: url, note: note, key: "trade:#{trade.id}:#{trade.status}")
        end
      end
    end
  end
end
