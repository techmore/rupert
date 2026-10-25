# frozen_string_literal: true

module AskRupert
  # Keep the policy outside this budget and retain whole turns, including their
  # tool exchanges. Never turn a truncated tool result into apparent evidence.
  module PromptBudget
    module_function

    def messages(messages, budget:)
      groups = []
      messages.each do |message|
        if groups.empty? || (message[:role].to_s == 'user' && !message[:content].to_s.start_with?('<tool_result'))
          groups << []
        end
        groups.last << message
      end
      kept = []
      remaining = budget
      groups.reverse_each do |group|
        size = group.sum { |message| message[:content].to_s.length + 32 }
        if size > remaining
          raise ProviderError.new('required prompt sections exceed the input budget', kind: :error) if kept.empty?

          break
        end
        kept.unshift(*group)
        remaining -= size
      end
      raise ProviderError.new('system prompt exceeds the input budget', kind: :error) if remaining.negative?

      kept
    end
  end
end
