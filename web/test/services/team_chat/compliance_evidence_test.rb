# frozen_string_literal: true

require 'test_helper'

class TeamChatComplianceEvidenceTest < ActiveSupport::TestCase
  test 'preserves close blockers and redacts personal details' do
    data = { items: [{ title: 'September: Review payments', area: 'Monthly close', status: 'fix', detail: 'Contact person@example.com' },
                     { title: 'Bank review', area: 'Books', status: 'watch' }, { title: 'Done', status: 'ok' }] }
    text = TeamChat::ComplianceEvidence.render([{ 'name' => 'compliance_check', 'result' => "result\n#{JSON.generate(data)}" }])
    assert_includes text, 'September: Review payments (Monthly close; fix)'
    assert_includes text, 'Bank review (Books; watch)'
    assert_not_includes text, 'person@example.com'
    assert_not_includes text, 'Done'
  end

  test 'does not treat truncated or unrelated results as a clear check' do
    assert_nil TeamChat::ComplianceEvidence.render([{ 'name' => 'compliance_check', 'result' => 'truncated' },
                                                    { 'name' => 'other', 'result' => "result\n{\"items\":[]}" }])
  end
end
