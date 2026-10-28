# frozen_string_literal: true

module TeamChat
  # The question bank (config/team_chat/question_bank/*.yml): hundreds of questions per area of Rupert, the way
  # the owners ask them, each labelled with the tools that should answer it and whether Rupert can answer it
  # at all. Scored without any model:
  # - routing: does the data guide (the keywords that pick a bot's tools) offer the tools the question needs?
  #   A hit is 1, no topic matched (the bot then gets every tool, unguided) is 0.5, wrong tools only is 0.
  # - coverage: can Rupert answer it (yes 1, partial 0.5, no 0)?
  # Misses show which keywords to add to the data guide; gaps show which tools (MCP/API) to build next.
  module QuestionBank
    DIR = Rails.root.join('config/team_chat/question_bank')
    # Always offered next to the topic tools (page and how-to lookups, record search, status).
    ALWAYS = Toolbox::LOOKUPS
    ANSWERABLE = { 'yes' => 1.0, 'partial' => 0.5, 'no' => 0.0 }.freeze

    Question = Struct.new(:id, :module, :question, :tools, :answerable, :gap, :expect, :checks, :needs, keyword_init: true)
    Check = Struct.new(:question, :topics, :offered, :outcome, :missing, keyword_init: true)
    ModuleScore = Struct.new(:module, :questions, :routing, :coverage, :hits, :fallbacks, :misses, :gaps, keyword_init: true)

    module_function

    def questions
      @questions = nil if Rails.env.development?
      @questions ||= Dir[DIR.join('*.yml')].sort.flat_map do |path|
        YAML.safe_load_file(path).fetch('questions').map do |row|
          Question.new(id: row.fetch('id'), module: row.fetch('module'), question: row.fetch('question').to_s,
            tools: Array(row['tools']).map(&:to_s), answerable: answerable(row.fetch('answerable')), gap: row['gap'].to_s.presence,
            expect: row['expect'].to_s.squish.presence, checks: row['checks'], needs: Array(row['needs']))
        end
      end
    end

    # YAML reads a bare yes/no as true/false.
    def answerable(value)
      { true => 'yes', false => 'no' }.fetch(value, value.to_s)
    end

    def check(question)
      topics = DataGuide.match(question.question)
      offered = topics.any? ? (DataGuide.tools_for(topics) + ALWAYS).uniq : nil
      needed = question.tools - ALWAYS
      outcome, missing =
        if needed.empty? then ['lookup', []]
        elsif offered.nil? then ['fallback', []]
        else
          gone = needed - offered
          [gone.empty? ? 'hit' : 'miss', gone]
        end
      Check.new(question: question, topics: topics.map(&:key), offered: offered, outcome: outcome, missing: missing)
    end

    def checks = questions.map { |question| check(question) }

    # One score per module, plus 'all'.
    def scores(list = checks)
      groups = list.group_by { |row| row.question.module }
      rows = groups.sort.map { |mod, rows_for| score(mod, rows_for) }
      rows << score('all', list) if groups.size > 1
      rows
    end

    def score(mod, list)
      routable = list.reject { |row| row.question.answerable == 'no' || row.outcome == 'lookup' }
      points = routable.sum { |row| { 'hit' => 1.0, 'fallback' => 0.5 }.fetch(row.outcome, 0.0) }
      ModuleScore.new(module: mod, questions: list.size,
        routing: (routable.any? ? (points / routable.size * 100).round : nil),
        coverage: (list.sum { |row| ANSWERABLE.fetch(row.question.answerable, 0.0) } / list.size * 100).round,
        hits: routable.count { |row| row.outcome == 'hit' }, fallbacks: routable.count { |row| row.outcome == 'fallback' },
        misses: routable.count { |row| row.outcome == 'miss' },
        gaps: list.count { |row| row.question.answerable != 'yes' })
    end

    # A fixed sample for the graded battery (BATTERY=bank): per module, `per` questions Rupert can answer at
    # least partly, plus one it cannot (graded under Honesty). The same seed gives the same sample, so runs compare.
    def battery_items(per: 5, seed: 1)
      questions.group_by(&:module).sort.flat_map do |_mod, list|
        rng = Random.new(seed)
        picked = list.reject { |question| question.answerable == 'no' }.sample(per, random: rng) +
                 list.select { |question| question.answerable == 'no' }.sample(1, random: rng)
        picked.map { |question| battery_item(question) }
      end
    end

    def battery_item(question)
      checks = question.checks || reference_checks(question.tools, question.question)
      # A generic partial-answer rubric cannot establish facts for a data
      # question whose reference arguments have not been authored.
      expect = if question.answerable == 'partial' && question.expect.blank? && checks.empty?
        nil
      else
        expectation(question)
      end
      Battery::Item.new(id: question.id, cadence: question.answerable == 'no' ? 'honesty' : 'bank', module: question.module,
        question: question.question, checks: checks, needs: question.needs, expect: expect)
    end

    # Only a navigation-only question can safely use a generated reference.
    # Defaults for data tools may silently select a different date or entity.
    def reference_checks(tools, question)
      return [] if tools.any? { |name| !%w[where_is how_do_i].include?(name) }

      tools.filter_map do |name|
        if %w[where_is how_do_i].include?(name)
          { 'tool' => name, 'args' => { 'query' => question.to_s.first(120) } }
        end
      end
    end

    def expectation(question)
      return question.expect if question.expect.present?

      case question.answerable
      when 'partial' then "Rupert can only partly answer this (#{question.gap}). A good answer gives what the tools show and says plainly what is missing."
      when 'no' then "Rupert has no data for this (#{question.gap}). A good answer says so plainly, invents no figures, and says where the answer could be found."
      end
    end

    # Plain-text report: scores, then the misses and the most common gaps per module.
    def report(limit: 15)
      list = checks
      lines = ['module        questions routing coverage  hits fallback miss gaps']
      scores(list).each do |row|
        lines << format('%-13s %9d %7s %8d %5d %8d %4d %4d', row.module, row.questions, row.routing || '-', row.coverage, row.hits, row.fallbacks, row.misses, row.gaps)
      end
      list.group_by { |row| row.question.module }.sort.each do |mod, rows_for|
        misses = rows_for.select { |row| row.outcome == 'miss' && row.question.answerable != 'no' }
        lines << '' << "== #{mod}: #{misses.size} misses (needed tool not offered)"
        misses.first(limit).each { |row| lines << "  #{row.question.id} needs #{row.missing.join(',')} | topics #{row.topics.join(',').presence || '-'} | #{row.question.question}" }
        fallbacks = rows_for.select { |row| row.outcome == 'fallback' && row.question.answerable != 'no' }
        lines << "   #{fallbacks.size} matched no topic, e.g. #{fallbacks.first(5).map { |row| row.question.question.inspect }.join('; ')}" if fallbacks.any?
        gaps = rows_for.filter_map { |row| row.question.gap if row.question.answerable != 'yes' }.tally.sort_by { |_, n| -n }.first(8)
        lines << "   top gaps: #{gaps.map { |gap, n| "#{gap} (#{n})" }.join(' · ')}" if gaps.any?
      end
      lines.join("\n")
    end
  end
end
