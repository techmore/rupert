# frozen_string_literal: true

require 'test_helper'

class TeamChatSyncEvidenceTest < ActiveSupport::TestCase
  test 'preserves source status while qualifying acquisition and unknown completeness' do
    data = { channels: [{ source: 'shopify', operation: 'catalog', latest_status: 'failed', last_success_at: '2026-10-27T12:00:00Z' },
                        { source: 'square', operation: 'catalog', latest_status: nil, last_success_at: nil }] }
    text = TeamChat::SyncEvidence.render([{ 'name' => 'sync_health', 'result' => "result\n#{JSON.generate(data)}" }])
    assert_includes text, 'shopify / catalog: failed; last successful acquisition 2026-10-27T12:00:00Z'
    assert_includes text, 'square / catalog: unknown; no known successful acquisition'
    assert_includes text, 'does not establish complete sales coverage'
  end

  test 'does not turn malformed or unrelated results into a healthy report' do
    assert_nil TeamChat::SyncEvidence.render([{ 'name' => 'sync_health', 'result' => 'truncated' }])
    assert_nil TeamChat::SyncEvidence.render([{ 'name' => 'other', 'result' => "result\n{\"channels\":[]}" }])
  end
end
