# frozen_string_literal: true

module Marketing
  # Redemptions and results of a marketing event (#415): counted from Rupert's stored orders (read-only, see
  # Marketing::RedemptionCount) or entered by hand. Rows live in marketing_results, not in the work-item table.
  class EventResultsController < BaseController
    before_action :set_event
    before_action { authorize(@event, :update?, policy_class: WorkItemPolicy) }
    rescue_from RedemptionCount::Refused, with: :refused

    # Count from stored orders.
    def count
      zone = WorkKinds.zone_for(@event)
      from = parse_local(zone, params[:from])
      to = parse_local(zone, params[:to])
      rows = RedemptionCount.call(@event, actor: Current.user, code: params[:code], from: from, to: to)
      total = rows.sum(&:redemptions)
      message = rows.empty? ? 'No stored orders used that code in the window.' : "Counted #{total} #{'order'.pluralize(total)} from stored orders."
      redirect_to(marketing_event_path(@event, anchor: 'event-results'), notice: message)
    end

    # Enter a result by hand (a paper tally, a partner's report). Saving the same code, location and currency again
    # replaces the earlier figures.
    def create
      attrs = params.require(:result).permit(:code, :currency, :redemptions, :revenue, :summary)
      result = Result.find_or_initialize_by(work_item_id: @event.id, code: attrs[:code].to_s.strip.upcase, order_source: '',
        location_id: @event.details['location_id'].to_s, currency: attrs[:currency].to_s.strip.upcase.presence || 'USD')
      result.assign_attributes(basis: 'manual', redemptions: integer(attrs[:redemptions]), revenue_cents: cents(attrs[:revenue]),
        summary: attrs[:summary].to_s.strip.presence, recorded_by: Current.user,
        window_starts_at: WorkKinds.local_time(@event, 'starts_at'), window_ends_at: WorkKinds.local_time(@event, 'ends_at'))
      result.offer = Offer.find_by(id: @event.details['offer_id'], code: result.code) if @event.details['offer_id'].present?
      if result.save
        ActivityLogger.log('marketing_event_result_saved', subject: @event, details: "#{result.code.presence || 'No code'}: #{result.redemptions}")
        redirect_to(marketing_event_path(@event, anchor: 'event-results'), notice: 'Result saved.')
      else
        redirect_to(marketing_event_path(@event, anchor: 'event-results'), alert: result.errors.full_messages.to_sentence)
      end
    end

    def destroy
      result = Result.where(work_item_id: @event.id).find(params[:id])
      result.destroy!
      ActivityLogger.log('marketing_event_result_removed', subject: @event, details: "#{result.code.presence || 'No code'} · #{result.basis_label}")
      redirect_to(marketing_event_path(@event, anchor: 'event-results'), notice: 'Result removed.')
    end

    private

    def set_event
      @event = Work::Item.of_kind('marketing_event').find(params[:event_id])
    end

    def parse_local(zone, text)
      return nil if text.blank? || zone.nil?

      zone.parse(text.to_s.first(16))
    rescue ArgumentError
      nil
    end

    def integer(text) = text.to_s.strip.match?(/\A\d+\z/) ? text.to_i : -1

    def cents(text)
      value = text.to_s.strip.delete(',').delete_prefix('$')
      return 0 if value.empty?
      return -1 unless value.match?(/\A\d+(\.\d{1,2})?\z/)

      (BigDecimal(value) * 100).to_i
    end

    def refused(error)
      redirect_to(marketing_event_path(@event, anchor: 'event-results'), alert: error.message)
    end
  end
end
