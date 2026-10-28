# frozen_string_literal: true

module TeamChat
  # The scoreboard on Model scores: every model's latest full test runs as 0–9 scores per axis, overall and per
  # app module, so a result reads "speed 6, quality 8, reliability 9" instead of one blended number. The axes stay
  # separate on purpose: fast-but-wrong and slow-but-right must look different.
  #
  #   quality      the grader's 1–5 mean mapped to 0–9 (1 = 0, 5 = 9)
  #   speed        each answer scores 9 up to FREE_SECONDS, then loses points evenly to 0 at the limit (SLOW_SECONDS);
  #                the score is the mean. Answers past the limit are ignored here and counted separately.
  #   reliability  answered questions out of attempted
  #   tool use     answers that called a Rupert tool
  #   grounding    answers with no figure the checker could not find in tool output
  #   first token  not recorded per question yet, so it shows as a dash until it is
  #
  # A blank is not a zero: an axis with nothing measured stays nil. Each model also carries the change since its
  # previous run of the same question sets, so improvement can be followed run over run.
  module Scorecard
    AXES = { 'quality' => 'Quality', 'speed' => 'Speed', 'first_token' => 'First token', 'reliability' => 'Reliability',
             'tool_use' => 'Tool use', 'grounding' => 'Grounding' }.freeze
    FREE_SECONDS = 20.0
    SLOW_SECONDS = ModelScores::SLOW_SECONDS.to_f
    # Hash the scale so a table is only compared with another produced by the same rules.
    SCALE = "quality=(grade-1)/4*9;speed=mean(9 to #{FREE_SECONDS}s then linear to 0 at #{SLOW_SECONDS}s; ignore beyond);reliability=answered/attempted;tool_use;grounding".freeze

    Card = Struct.new(:model, :handle, :where, :overall, :modules, :graded, :change, :tested_at, :timing, keyword_init: true)
    # Real seconds behind the speed score: the median and slow tail of answers, how many ran past the limit, and model load time.
    # Median, p95 and slowest are of answers within the limit; slow is how many took longer than FREE_SECONDS; ignored is how many
    # passed the limit and are left out of the speed score and these figures.
    Timing = Struct.new(:median, :p95, :slowest, :slow, :ignored, :answered, :load, keyword_init: true)

    module_function

    def call(sort: 'quality')
      runs = Leaderboard.latest_runs
      previous = previous_runs(runs)
      runs.group_by(&:model).filter_map do |model, list|
        results = list.flat_map(&:results_list)
        overall = scores(results)
        next if overall.values.compact.empty?

        modules = results.group_by { |result| Leaderboard.column_for(result) }.transform_values { |rows| scores(rows) }
        before = previous.select { |run| run.model == model }
        Card.new(model: model, handle: Leaderboard.handle_for(model, list), where: list.first.engine == 'local_gateway' ? 'local' : 'cloud',
          overall: overall, modules: modules, graded: list.sum { |run| run.results_list.count { |row| row['grade'] } },
          change: before.empty? ? {} : change(overall, scores(before.flat_map(&:results_list))), tested_at: list.filter_map(&:started_at).max,
          timing: timing(results))
      end.sort_by { |card| [-(card.overall[sort] || -1), -(card.overall['quality'] || -1)] }
    end

    # One 0–9 score per axis for a set of saved results; nil where nothing was measured.
    def scores(results)
      done = results.select { |row| row['status'].blank? || row['status'] == 'done' }
      graded = results.filter_map { |row| row['grade'] if row['grade'].is_a?(Numeric) }
      times = answer_times(done)
      {
        'quality' => (scale((graded.sum.to_f / graded.size - 1) / 4) if graded.any?),
        'speed' => (scale(times.sum { |value| speed_fraction(value) } / times.size) if times.any?),
        'first_token' => nil,
        'reliability' => (scale(done.size.to_f / results.size) if results.any?),
        'tool_use' => (scale(done.count { |row| Array(row['tools']).any? }.to_f / done.size) if done.any?),
        'grounding' => (scale(done.count { |row| Array(row['unverified']).empty? }.to_f / done.size) if done.any?)
      }
    end

    def timing(results)
      done = results.select { |row| row['status'].blank? || row['status'] == 'done' }
      all = done.filter_map { |row| row['seconds'].to_f if row['seconds'].to_f.positive? }
      times = answer_times(done).sort
      loads = done.filter_map { |row| row['load_seconds'].to_f if row['load_seconds'].to_f.positive? }.sort
      ignored = all.size - times.size
      return Timing.new(answered: 0, slow: 0, ignored: ignored) if times.empty?

      Timing.new(median: times[times.size / 2].round(1), p95: times[[(times.size * 0.95).ceil - 1, 0].max].round(1), slowest: times.last.round(1),
        slow: times.count { |value| value > FREE_SECONDS }, ignored: ignored, answered: times.size, load: (loads[loads.size / 2].round(1) if loads.any?))
    end

    # Seconds of the answers that count: past the limit they are ignored.
    def answer_times(done) = done.filter_map { |row| row['seconds'].to_f if row['seconds'].to_f.positive? && row['seconds'].to_f <= SLOW_SECONDS }

    def scale(fraction) = (fraction.clamp(0.0, 1.0) * 9).round

    # 1.0 up to FREE_SECONDS, then falling evenly to 0.0 at SLOW_SECONDS.
    def speed_fraction(seconds) = 1 - ((seconds - FREE_SECONDS) / (SLOW_SECONDS - FREE_SECONDS)).clamp(0.0, 1.0)

    # The second-newest run of every model and question set, to show movement.
    def previous_runs(latest)
      newest = latest.map(&:id)
      BatteryRun.where.not(model: [nil, '']).where.not('set_name LIKE ?', '%(part)%').newest_first.to_a
                .select { |run| run.status == 'done' && newest.exclude?(run.id) }
                .uniq { |run| [run.model, run.set_name] }
    end

    def change(now, before)
      AXES.keys.each_with_object({}) { |axis, diff| diff[axis] = now[axis] - before[axis] if now[axis] && before[axis] }
    end

    def scale_hash = Digest::SHA256.hexdigest(SCALE).first(12)
  end
end
