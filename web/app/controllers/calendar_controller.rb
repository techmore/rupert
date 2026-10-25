# frozen_string_literal: true

# One calendar for task deadlines and marketing events (#417), read across kinds of the shared work-item table
# (Work::Calendar). Each kind shows only what its own policy lets the viewer see.
class CalendarController < AuthenticatedController
  VIEWS = %w[month agenda].freeze
  SHOW = { 'all' => nil, 'tasks' => %w[task], 'marketing' => %w[marketing_event campaign_task] }.freeze

  def show
    raise Pundit::NotAuthorizedError unless ModuleRegistry.visible?(Current.user, 'calendar')

    @view = params[:view].presence_in(VIEWS) || 'month'
    @show = params[:show].presence_in(SHOW.keys) || 'all'
    @month = parse_month(params[:month])
    @days = (@month.beginning_of_week(:monday)..@month.end_of_month.end_of_week(:monday)).to_a
    range = @view == 'month' ? [@days.first, @days.last] : [@month, @month.end_of_month]
    @calendar = Work::Calendar.new(user: Current.user, from: range.first, to: range.last, kinds: SHOW[@show])
    @all_kinds = Work::Calendar.new(user: Current.user, from: range.first, to: range.last).visible_kinds.map(&:key)
  end

  private

  def parse_month(text)
    Date.strptime(text.to_s, '%Y-%m').beginning_of_month.clamp(Date.new(2000, 1, 1), Date.new(2100, 12, 1))
  rescue ArgumentError
    Date.current.beginning_of_month
  end
end
