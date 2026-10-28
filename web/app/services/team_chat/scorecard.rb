# frozen_string_literal: true

module TeamChat
  # The scoreboard on Model scores: every model's latest full test runs as 0–9 scores per axis, overall and per
  # app module, so a result reads "speed 6, quality 8, reliability 9" instead of one blended number. The axes stay
  # separate on purpose: fast-but-wrong and slow-but-right must look different.
  #
  #   quality      the grader's 1–5 mean mapped to 0–9 (1 = 0, 5 = 9)
  #   speed        median answer time on a log scale: 9 at FAST_SECONDS or less, 0 at the SLA (SLOW_SECONDS)
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
    FAST_SECONDS = 2.0
    SLOW_SECONDS = ModelScores::SLOW_SECONDS.to_f
    # Hash the scale so a table is only compared with another produced by the same rules.
    SCALE = "quality=(grade-1)/4*9;speed=log(#{FAST_SECONDS}s..#{SLOW_SECONDS}s);reliability=answered/attempted;tool_use;grounding".freeze

    Card = Struct.new(:model, :handle, :where, :overall, :modules, :graded, :change, :tested_at, keyword_init: true)

    module_function

    def call
      runs = Leaderboard.latest_runs
      previous = previous_runs(runs)
      runs.group_by(&:model).filter_map do |model, list|
        overall = scores(list.flat_map(&:results_list))
        next if overall.values.compact.empty?

        modules = list.flat_map(&:results_list).group_by { |result| Leaderboard.column_for(result) }.transform_values { |rows| scores(rows) }
        before = previous.select { |run| run.model == model }
        Card.new(model: model, handle: Leaderboard.handle_for(model, list), where: list.first.engine == 'local_gateway' ? 'local' : 'cloud',
          overall: overall, modules: modules, graded: list.sum { |run| run.results_list.count { |row| row['grade'] } },
          change: before.empty? ? {} : change(overall, scores(before.flat_map(&:results_list))), tested_at: list.filter_map(&:started_at).max)
      end.sort_by { |card| [-(card.overall['quality'] || -1), -(card.overall['speed'] || -1)] }
    end

    # One 0–9 score per axis for a set of saved results; nil where nothing was measured.
    def scores(results)
      done = results.select { |row| row['status'].blank? || row['status'] == 'done' }
      graded = results.filter_map { |row| row['grade'] if row['grade'].is_a?(Numeric) }
      times = done.filter_map { |row| row['seconds'].to_f if row['seconds'].to_f.positive? }.sort
      {
        'quality' => (scale((graded.sum.to_f / graded.size - 1) / 4) if graded.any?),
        'speed' => (speed(times[times.size / 2]) if times.any?),
        'first_token' => nil,
        'reliability' => (scale(done.size.to_f / results.size) if results.any?),
        'tool_use' => (scale(done.count { |row| Array(row['tools']).any? }.to_f / done.size) if done.any?),
        'grounding' => (scale(done.count { |row| Array(row['unverified']).empty? }.to_f / done.size) if done.any?)
      }
    end

    def scale(fraction) = (fraction.clamp(0.0, 1.0) * 9).round

    def speed(seconds)
      clamped = seconds.clamp(FAST_SECONDS, SLOW_SECONDS)
      scale(1 - (Math.log(clamped / FAST_SECONDS) / Math.log(SLOW_SECONDS / FAST_SECONDS)))
    end

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
