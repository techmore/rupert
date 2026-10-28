# frozen_string_literal: true

require 'test_helper'

class TeamChatQueueEvidenceTest < ActiveSupport::TestCase
  test 'scopes only complete requests for supported queues' do
    scope = TeamChat::QueueEvidence.method(:requested_queues)
    assert_equal ['Expense receipts waiting for review'], scope.call('@lfm3-text How many expense receipts are awaiting review?')
    assert_equal ['Reconciliation follow-ups'], scope.call('Any reconciliation follow-ups waiting?')
    assert_equal ['Expense receipts waiting for review', 'Purchase orders awaiting delivery'],
      scope.call('What receipts need review and are any purchase orders late?')
    assert_nil scope.call('What receipts need review and what are sales today?')
    assert_nil scope.call('How do I review receipts?')
    assert_nil scope.call('Receipts to review for the downtown store?')
    assert_nil scope.call('Are any POS late?')
  end

  test 'requires every requested count and does not claim an unavailable late count is zero' do
    context = { 'queues' => [{ 'name' => 'Expense receipts waiting for review', 'count' => 0 },
                             { 'name' => 'Purchase orders awaiting delivery', 'count' => 1 }] }
    evidence = [{ 'queue_summary' => context }]
    text = TeamChat::QueueEvidence.render_requested(evidence, 'What receipts need review and are any purchase orders late?')
    assert_includes text, 'Expense receipts waiting for review: 0'
    assert_includes text, 'Purchase orders awaiting delivery: 1; late count unavailable'
    assert_includes text, 'counts, not individual'
    context['queues'].first['count'] = 2
    assert_nil TeamChat::QueueEvidence.render_requested(evidence, 'What receipts need review and are any purchase orders late?')
    assert_includes TeamChat::QueueEvidence.render_requested(evidence, 'How many expense receipts are awaiting review?'), 'review: 2'
    context['queues'].pop
    assert_nil TeamChat::QueueEvidence.render_requested(evidence, 'What receipts need review and are any purchase orders late?')
  end
end
