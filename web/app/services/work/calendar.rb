# frozen_string_literal: true

module Work
  # The shared calendar (#417): every work item a person may see that falls in a date range, across kinds — task
  # deadlines (due_on), campaign task deadlines and marketing events (start_on through due_on, the event's local
  # dates). Each kind is narrowed through its own policy scope (Work::Kind#visible_to), and the kinds are combined
  # into one query for the range, so the page costs the same however many kinds there are.
  class Calendar
    LIMIT = 1000

    Entry = Data.define(:item, :kind, :first_day, :last_day, :starts_at, :ends_at, :time_zone, :place, :path, :overdue) do
      def all_day? = starts_at.nil?
      def days = (first_day..last_day)
    end

    attr_reader :from, :to

    def initialize(user:, from:, to:, kinds: nil)
      @user = user
      @from = from
      @to = to
      @kinds = Work::Registry.calendar_kinds.select { |kind| kinds.nil? || kinds.include?(kind.key) }
    end

    # Kinds this person may see at all (whatever the dates), for the filter.
    def visible_kinds
      @visible_kinds ||= @kinds.reject { |kind| kind.visible_to(@user, Work::Item.all).null_relation? }
    end

    def visible? = visible_kinds.any?

    def entries
      @entries ||= load_entries
    end

    def truncated? = entries && @truncated

    def by_day
      @by_day ||= entries.each_with_object(Hash.new { |hash, day| hash[day] = [] }) do |entry, days|
        ([entry.first_day, from].max..[entry.last_day, to].min).each { |day| days[day] << entry }
      end
    end

    private

    def load_entries
      relations = visible_kinds.map { |kind| in_range(kind, kind.visible_to(@user, Work::Item.all)) }
      return [] if relations.empty?

      items = relations.reduce { |combined, relation| combined.or(relation) }
        .includes(:assignee).order(Arel.sql('COALESCE(tasks.start_on, tasks.due_on)'), :id).limit(LIMIT + 1).to_a
      @truncated = items.size > LIMIT
      items = items.first(LIMIT)
      locations = location_names(items)
      items.map { |item| entry_for(item, locations) }.sort_by { |entry| [entry.first_day, entry.starts_at ? 0 : 1, entry.starts_at.to_i, entry.item.id] }
    end

    def in_range(kind, relation)
      case kind.calendar
      when :span then relation.where(start_on: ..to, due_on: from..)
      else relation.where(due_on: from..to)
      end
    end

    def location_names(items)
      ids = items.filter_map { |item| item.details['location_id'].presence }.uniq
      ids.empty? ? {} : Location.where(externalId: ids).pluck(:externalId, :name).to_h
    end

    def entry_for(item, locations)
      kind = item.kind_definition
      if kind.calendar == :span
        starts = Marketing::WorkKinds.local_time(item, 'starts_at')
        ends = Marketing::WorkKinds.local_time(item, 'ends_at')
        details = item.details
        place = [details['venue'].presence, locations[details['location_id']],
                 Marketing::WorkKinds::CHANNELS[details['channel']]].compact.uniq.join(' · ')
        Entry.new(item:, kind:, first_day: item.start_on, last_day: item.due_on || item.start_on, starts_at: starts, ends_at: ends,
          time_zone: starts&.time_zone, place: place.presence, path: item.work_path, overdue: false)
      else
        overdue = item.due_on < Date.current && !kind.done_statuses.include?(item.status)
        Entry.new(item:, kind:, first_day: item.due_on, last_day: item.due_on, starts_at: nil, ends_at: nil, time_zone: nil, place: nil,
          path: item.work_path, overdue: overdue)
      end
    end
  end
end
