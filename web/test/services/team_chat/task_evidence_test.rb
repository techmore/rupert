# frozen_string_literal: true

require 'test_helper'

class TeamChatTaskEvidenceTest < ActiveSupport::TestCase
  test 'empty later pages preserve filters without claiming the whole board is empty' do
    entry = { 'name' => 'list_tasks', 'arguments' => { 'query' => 'tea', 'page' => 2 },
              'result' => "result\n#{JSON.generate(rows: [], meta: { has_more: false })}" }
    text = TeamChat::TaskEvidence.render([entry])
    assert_includes text, 'query: tea, page: 2'
    assert_includes text, 'No tasks were returned on this page'
  end

  test 'ignores non-task and truncated results and bounds personal data' do
    data = { rows: [{ title: 'Recount person@example.com', status: 'todo', due_on: '2026-10-31' }], meta: { has_more: true } }
    entry = { 'name' => 'list_tasks', 'arguments' => {}, 'result' => "result\n#{JSON.generate(data)}" }
    text = TeamChat::TaskEvidence.render([entry, { 'name' => 'search', 'result' => entry['result'] },
                                          { 'name' => 'list_tasks', 'result' => 'truncated' }])
    assert_includes text, 'Recount'
    assert_not_includes text, 'person@example.com'
    assert_includes text, 'due 2026-10-31'
    assert_includes text, 'paginated'
    assert_equal 1, text.scan('Task lookup').size
  end
end
