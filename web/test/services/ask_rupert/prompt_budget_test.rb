# frozen_string_literal: true

require 'test_helper'

class AskRupertPromptBudgetTest < ActiveSupport::TestCase
  test 'oversized CLI history preserves policy and the complete current tool exchange' do
    messages = [{ role: 'user', content: 'old question' }, { role: 'assistant', content: 'x' * 30_000 },
                { role: 'user', content: 'current question' },
                { role: 'assistant', content: 'TOOL_CALL: {"name":"where_is","arguments":{"query":"sync"}}' },
                { role: 'user', content: '<tool_result name="where_is">source evidence</tool_result>' }]
    prompt = AskRupert::Providers::Opencode.new.send(:build_prompt, 'KEEP POLICY AND SCHEMAS', messages)
    assert prompt.start_with?('KEEP POLICY AND SCHEMAS')
    assert_includes prompt, 'current question'
    assert_includes prompt, 'source evidence'
    assert_includes prompt, 'TOOL_CALL:'
    refute_includes prompt, 'old question'
    assert_operator prompt.length, :<=, AskRupert::Providers::Opencode::MAX_PROMPT_CHARS
  end

  test 'cannot silently truncate policy or current evidence even if it alone is too large' do
    provider = AskRupert::Providers::Opencode.new
    assert_raises(AskRupert::ProviderError) { provider.send(:build_prompt, 'policy' * 6000, []) }
    assert_raises(AskRupert::ProviderError) { provider.send(:build_prompt, 'policy', [{ role: 'user', content: 'x' * 30_000 }]) }
  end
end
