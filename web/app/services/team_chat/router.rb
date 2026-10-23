# frozen_string_literal: true

module TeamChat
  # Picks who answers a question that names no bot (config/team_chat/routing.yml): general questions go to a
  # fast local bot, finance to @rupert and the local bot side by side, questions that join finance with another
  # area to @rupert, and "think harder" to the careful local bot. An @mention always wins over this.
  module Router
    CONFIG = Rails.root.join('config/team_chat/routing.yml')
    THINK = /\b(?:think (?:harder|hard|deeper|deeply|carefully|it through)|take your time|dig deeper)\b/i
    # Topics that say nothing about which area a question is in.
    NEUTRAL = %w[comparison cross].freeze

    # kind: general / finance / cross / think. handles: who answers, "rupert" for @rupert.
    Route = Struct.new(:kind, :handles, keyword_init: true)

    module_function

    def config = @config ||= YAML.safe_load_file(CONFIG).freeze

    def kind_for(text)
      return 'think' if text.to_s.match?(THINK)

      keys = DataGuide.match(text).map(&:key) - NEUTRAL
      finance = keys & Array(config['finance_topics'])
      return 'cross' if finance.any? && (keys - finance).any?

      finance.any? ? 'finance' : 'general'
    end

    def route(text)
      kind = kind_for(text)
      Route.new(kind: kind, handles: Array(config[kind]).map(&:to_s).presence || ['rupert'])
    end

    # The bots for this question: [rupert?, local agents]. A local bot that is not available drops out;
    # if none is left, @rupert answers.
    def answerers(text)
      route = route(text)
      agents = route.handles.reject { |handle| handle == 'rupert' }.filter_map { |handle| LocalAgents.find(handle) || LocalAgents.trial(handle) }
      rupert = route.handles.include?('rupert') || agents.empty?
      [route, rupert, agents]
    end
  end
end
