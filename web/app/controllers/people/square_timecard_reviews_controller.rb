# frozen_string_literal: true

module People
  # Square timecards edited or removed in Square after import, grouped by staff
  # member and pay period, with Accept (take Square's latest hours) and Keep original.
  class SquareTimecardReviewsController < AuthenticatedController
    PER_PAGE = 50

    before_action -> { response.headers['Cache-Control'] = 'no-store' }
    before_action :require_reviewer

    def index
      scope = SquareTimecardReviewer.queue
      scope = scope.where(employee_id: params[:employee_id]) if params[:employee_id].present?
      @employees = People::Employee.where(id: SquareTimecardReviewer.queue.select(:employee_id)).order(:last_name, :first_name)
      @pagy, cards = pagy(:offset, scope.order(:employee_id, :started_at, :id), limit: PER_PAGE)
      @reviews = cards.map { |card| SquareTimecardReviewer.new(card) }
      @groups = @reviews.group_by { |review| review.card.employee }.transform_values do |rows|
        rows.group_by { |review| PayRules.current.period_range(local_day(review.card)) }
      end
      @waiting = scope.count
      @counted_seconds = @reviews.sum { |review| review.comparison[:counted][:seconds] }
      @latest_seconds = @reviews.sum { |review| review.comparison[:latest][:seconds] }
    end

    def create
      card = SquareTimecard.find(params[:id])
      reviewer = SquareTimecardReviewer.new(card)
      permitted = params.require(:square_review).permit(:decision, :reason, :seen_key)
      review = case permitted[:decision]
               when 'accept' then reviewer.accept!(reason: permitted[:reason], seen_key: permitted[:seen_key])
               when 'keep' then reviewer.keep!(reason: permitted[:reason], seen_key: permitted[:seen_key])
               else raise SquareTimecardReviewer::Error, 'Choose Accept or Keep original.'
               end
      notice = { 'accepted' => 'Square’s hours now count. The change is in the timecard’s history.',
                 'kept' => 'Original hours kept. The decision is in the timecard’s history.' }[review.decision]
      return redirect_back_or_to(people_square_timecard_reviews_path, notice: notice) if notice

      redirect_back_or_to people_square_timecard_reviews_path, alert: "Not applied: #{review.held_by} is locked. Original hours still count; the timesheet is flagged."
    rescue SquareTimecardReviewer::Error, ActiveRecord::RecordInvalid => e
      redirect_back_or_to people_square_timecard_reviews_path, alert: e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
    end

    private

    def require_reviewer
      skip_authorization # gate: SquareTimecardReviewer.allowed? (timesheets read + write, this workspace)
      raise Pundit::NotAuthorizedError unless SquareTimecardReviewer.allowed?(Current.user)
    end

    def local_day(card)
      card.started_at.in_time_zone(card.timezone.presence || Time.zone).to_date
    end
  end
end
